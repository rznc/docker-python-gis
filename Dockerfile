# GDAL build mostly copied from the project's Dockerfile:
# https://github.com/OSGeo/gdal/blob/master/gdal/docker/alpine-normal/Dockerfile
# Supported versions: https://docs.djangoproject.com/en/3.0/ref/contrib/gis/install/geolibs/
ARG ALPINE_VERSION=3.13.3
FROM alpine:${ALPINE_VERSION} as builder

# Setup build env for PROJ
RUN apk add --no-cache wget curl unzip make libtool autoconf automake pkgconfig g++ sqlite sqlite-dev

ARG PROJ_DATUMGRID_VERSION=1.8
RUN set -ex; \
    mkdir -p /build_projgrids/usr/share/proj; \
    curl -LOs http://download.osgeo.org/proj/proj-datumgrid-${PROJ_DATUMGRID_VERSION}.zip; \
    unzip -q -j -u -o proj-datumgrid-${PROJ_DATUMGRID_VERSION}.zip \
        -d /build_projgrids/usr/share/proj; \
    rm -f *.zip

# For PROJ and GDAL
RUN set -ex; \
    apk add --no-cache \
        curl-dev \
        expat-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libxml2-dev \
        linux-headers \
        openexr-dev \
        openjpeg-dev \
        postgresql-dev \
        py3-numpy \
        py3-numpy-dev \
        python3-dev \
        tiff-dev \
        zlib-dev \
        zstd-dev \
    ; \
    mkdir -p /build_thirdparty/usr/lib

# Build geos
ARG GEOS_VERSION=3.8.1
RUN set -ex; \
    mkdir geos; \
    wget -q http://download.osgeo.org/geos/geos-${GEOS_VERSION}.tar.bz2 -O - \
        | tar xj -C geos --strip-components=1; \
    cd geos; \
    ./configure --prefix=/usr --disable-static; \
    make -j$(nproc); \
    make install; \
    cd ..; \
    rm -rf geos; \
    cp -P /usr/lib/libgeos*.so* /build_thirdparty/usr/lib; \
    for i in /build_thirdparty/usr/lib/*; do strip -s $i 2>/dev/null || /bin/true; done

# Build PROJ
ARG PROJ_VERSION=6.3.2
RUN set -ex; \
    mkdir proj; \
    wget -q https://github.com/OSGeo/PROJ/archive/${PROJ_VERSION}.tar.gz -O - \
        | tar xz -C proj --strip-components=1; \
    cd proj; \
    ./autogen.sh; \
    ./configure --prefix=/usr --disable-static --enable-lto; \
    make -j$(nproc); \
    make install; \
    make install DESTDIR="/build_proj"; \
    cd ..; \
    rm -rf proj; \
    for i in /build_proj/usr/lib/*; do strip -s $i 2>/dev/null || /bin/true; done; \
    for i in /build_proj/usr/bin/*; do strip -s $i 2>/dev/null || /bin/true; done

# Build GDAL
ARG GDAL_VERSION=3.1.2
RUN set -ex; \
    export GDAL_EXTRA_ARGS="--with-geos"; \
    mkdir gdal; \
    wget -q https://github.com/OSGeo/gdal/archive/v${GDAL_VERSION}.tar.gz -O - \
        | tar xz -C gdal --strip-components=1; \
    cd gdal/gdal; \
    ./configure --prefix=/usr --without-libtool \
        --with-hide-internal-symbols \
        --with-proj=/usr \
        --with-libtiff=internal --with-rename-internal-libtiff-symbols \
        --with-geotiff=internal --with-rename-internal-libgeotiff-symbols \
        # --enable-lto
        ${GDAL_EXTRA_ARGS} \
        --with-python \
    ; \
    make -j$(nproc); \
    make install DESTDIR="/build"; \
    cd ../..; \
    rm -rf gdal; \
    mkdir -p /build_gdal_python/usr/lib; \
    mkdir -p /build_gdal_python/usr/bin; \
    mkdir -p /build_gdal_version_changing/usr/include; \
    mv /build/usr/lib/python3.8          /build_gdal_python/usr/lib; \
    mv /build/usr/lib                    /build_gdal_version_changing/usr; \
    mv /build/usr/include/gdal_version.h /build_gdal_version_changing/usr/include; \
    mv /build/usr/bin/*.py               /build_gdal_python/usr/bin; \
    mv /build/usr/bin                    /build_gdal_version_changing/usr; \
    for i in /build_gdal_version_changing/usr/lib/*; do \
        strip -s $i 2>/dev/null || /bin/true; \
    done; \
    for i in /build_gdal_python/usr/lib/python3.8/site-packages/osgeo/*.so; do \
        strip -s $i 2>/dev/null || /bin/true; \
    done; \
    for i in /build_gdal_version_changing/usr/bin/*; do \
        strip -s $i 2>/dev/null || /bin/true; \
    done; \
    # Remove resource files of uncompiled drivers
    (for i in \
        # unused
        /build/usr/share/gdal/*.svg \
        # unused
        /build/usr/share/gdal/*.png \
    ; do rm $i; done)

RUN echo "Geo/GDAL builder completed"



# Build final image
FROM alpine:${ALPINE_VERSION} as runner

RUN set -ex; \
    apk add --no-cache --virtual .gdal-deps \
        expat \
        libcurl \
        tiff \
        libjpeg-turbo \
        libpng \
        libpq \
        libstdc++ \
        libwebp \
        libxml2 \
        openexr \
        openjpeg \
        pcre \
        portablexdr \
        python3 \
        sqlite-libs \
        zlib \
        zstd-libs\
    ; \
    ln -s /usr/bin/python3 /usr/bin/python; \
    python -m ensurepip; \
    ln -s /usr/bin/pip3 /usr/bin/pip; \
    pip install --no-cache-dir --upgrade pip wheel

# Order layers starting with less frequently varying ones
COPY --from=builder  /build_thirdparty/usr/ /usr/
COPY --from=builder  /build_projgrids/usr/ /usr/

COPY --from=builder  /build_proj/usr/share/proj/ /usr/share/proj/
COPY --from=builder  /build_proj/usr/include/ /usr/include/
COPY --from=builder  /build_proj/usr/bin/ /usr/bin/
COPY --from=builder  /build_proj/usr/lib/ /usr/lib/

COPY --from=builder  /build/usr/share/gdal/ /usr/share/gdal/
COPY --from=builder  /build/usr/include/ /usr/include/
COPY --from=builder  /build_gdal_python/usr/ /usr/
COPY --from=builder  /build_gdal_version_changing/usr/ /usr/

# Additional Python packages
RUN set -ex; \
    BUILD_DEPS=" \
        g++ \
        python3-dev \
    "; \
    RUN_DEPS=" \
        py3-cffi \
        py3-cryptography \
        py3-psycopg2 \
    "; \
    export CFLAGS="-Os -g0 -Wl,--strip-all"; \
    apk add --no-cache --virtual .build-deps $BUILD_DEPS $RUN_DEPS; \
    pip install --no-cache-dir --compile --global-option=build_ext --global-option=-j4 \
        regex==2020.7.14 \
    ; \
    EXTRA_RUN_DEPS="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/lib/python3.8 \
        | tr ',' '\n' \
        | sort -u \
        | grep -v '^libgdal.so$' \
        | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache $EXTRA_RUN_DEPS $RUN_DEPS; \
    apk del --no-cache .build-deps; \
    rm -rf /root/.cache
