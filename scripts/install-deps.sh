#! /bin/sh

set -ex

# Special environment variable to be used when only fetching and extracting
# embedded dependencies should be done, i.e. no system package manager is
# being invoked.
#
# set this as environment variable to ON to activate this mode.
if [ x$PREPARE_ONLY_EMBEDS = x ]
then
    PREPARE_ONLY_EMBEDS=OFF
fi

# if SYSDEP_ASSUME_YES=ON is set, then system package managers are attempted
# to install packages automatically, i.e. without confirmation.
if [ x$SYSDEP_ASSUME_YES = xON ]
then
    SYSDEP_ASSUME_YES='-y'
else
    unset SYSDEP_ASSUME_YES
fi

# {{{ sysdeps fetcher and unpacker for deps that aren't available via sys pkg mgnr
SYSDEPS_BASE_DIR="$(dirname $0)/../_deps"

SYSDEPS_DIST_DIR="$SYSDEPS_BASE_DIR/distfiles"
SYSDEPS_SRC_DIR="$SYSDEPS_BASE_DIR/sources"
SYSDEPS_CMAKE_FILE="$SYSDEPS_SRC_DIR/CMakeLists.txt"

fetch_and_unpack()
{
    NAME=$1
    DISTFILE=$2
    URL=$3

    FULL_DISTFILE="$SYSDEPS_DIST_DIR/$DISTFILE"

    if ! test -f "$FULL_DISTFILE"; then
        if which curl &>/dev/null; then
            curl -L -o "$FULL_DISTFILE" "$URL"
        elif which wget &>/dev/null; then
            wget -O "$FULL_DISTFILE" "$URL"
        elif which fetch &>/dev/null; then
            # FreeBSD
            fetch -o "$FULL_DISTFILE" "$URL"
        else
            echo "Don't know how to fetch from the internet." 1>&2
            exit 1
        fi
    else
        echo "Already fetched $DISTFILE. Skipping."
    fi

    if ! test -d "$SYSDEPS_SRC_DIR/$NAME"; then
        echo "Extracting $DISTFILE"
        tar xzpf $FULL_DISTFILE -C $SYSDEPS_SRC_DIR
    else
        echo "Already extracted $DISTFILE. Skipping."
    fi

    echo "add_subdirectory($NAME EXCLUDE_FROM_ALL)" >> $SYSDEPS_CMAKE_FILE
}

fetch_and_unpack_Catch2()
{
    fetch_and_unpack \
        Catch2-3.4.0 \
        Catch2-3.4.0.tar.gz \
        https://github.com/catchorg/Catch2/archive/refs/tags/v3.4.0.tar.gz
}

fetch_and_unpack_fmtlib()
{
    fetch_and_unpack \
        fmt-9.1.0 \
        fmtlib-9.1.0.tar.gz \
        https://github.com/fmtlib/fmt/archive/refs/tags/9.1.0.tar.gz
}

fetch_and_unpack_yaml_cpp()
{
    fetch_and_unpack \
        yaml-cpp-yaml-cpp-0.7.0 \
        yaml-cpp-0.7.0.tar.gz \
        https://github.com/jbeder/yaml-cpp/archive/refs/tags/yaml-cpp-0.7.0.tar.gz
}

prepare_fetch_and_unpack()
{
    mkdir -p "${SYSDEPS_BASE_DIR}"
    mkdir -p "${SYSDEPS_DIST_DIR}"
    mkdir -p "${SYSDEPS_SRC_DIR}"

    # empty out sysdeps CMakeLists.txt
    rm -f $SYSDEPS_CMAKE_FILE
}
# }}}

install_deps_ubuntu()
{
    local packages="
        build-essential
        cmake
        debhelper
        dpkg-dev
        g++
        libc6-dev
        make
    "

    if [ ! "$COMPILER" = "" ]; then
        local PKGVER=`echo $COMPILER | awk '{print $2}'`
        local PKGNAME=`echo $COMPILER | awk '{print tolower($1);}'`
        test "$PKGNAME" = "gcc" && PKGNAME="g++"
        packages="$packages $PKGNAME-$PKGVER"
    fi

    RELEASE=`grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"'`

    local NAME=`grep ^NAME /etc/os-release | cut -d= -f2 | cut -f1 | tr -d '"'`

    if [ ! "${NAME}" = "Debian GNU/Linux" ]; then
        # We cannot use [[ nor < here because that's not in /bin/sh.
        if [ "$RELEASE" = "18.04" ]; then
            # Old Ubuntu's (especially 18.04 LTS) doesn't have a proper std::filesystem implementation.
            #packages+=libboost-all-dev
            packages="$packages g++-8"
        fi
    fi

    case $RELEASE in
        "18.04" | "19.04" | "20.04" | "21.04" | "22.04")
            fetch_and_unpack_fmtlib
            fetch_and_unpack_Catch2
            ;;
        *)
            packages="$packages libfmt-dev catch2"
            ;;
    esac

    [ x$PREPARE_ONLY_EMBEDS = xON ] && return

    sudo apt install $SYSDEP_ASSUME_YES $packages
    # sudo snap install --classic powershell
}

install_deps_FreeBSD()
{
    [ x$PREPARE_ONLY_EMBEDS = xON ] && return

    su root -c "pkg install $SYSDEP_ASSUME_YES \
        catch \
        cmake \
        libfmt \
        ninja \
        pkgconf \
        range-v3
    "
}

install_deps_arch()
{
    fetch_and_unpack_fmtlib
    [ x$PREPARE_ONLY_EMBEDS = xON ] && return

    pacman -S -y \
        catch2 \
        cmake \
        git \
        ninja \
        range-v3
}

install_deps_fedora()
{
    version=`cat /etc/fedora-release | awk '{print $3}'`

    local packages="
        cmake
        gcc-c++
        ninja-build
        pkgconf
        range-v3-devel
    "

    # Fedora 37+ contains fmtlib 9.1.0+, prefer this and fallback to embedding otherwise.
    # Fedora 38+ contains Catch2 3.0.0+, prefer this and fallback to embedding otherwise.
    [ $version -ge 37 ] && packages="$packages fmt-devel" || fetch_and_unpack_fmtlib
    [ $version -ge 38 ] && packages="$packages catch-devel" || fetch_and_unpack_Catch2

    [ x$PREPARE_ONLY_EMBEDS = xON ] && return

    sudo dnf install $SYSDEP_ASSUME_YES $packages
}


install_deps_darwin()
{
    fetch_and_unpack_Catch2

    [ x$PREPARE_ONLY_EMBEDS = xON ] && return

    # NB: Also available in brew: mimalloc
    # catch2: available in brew, but too new (version 3+)
    brew install $SYSDEP_ASSUME_YES \
        fmt \
        pkg-config \
        range-v3
}

main()
{
    if test x$OS_OVERRIDE != x; then
        # In CI, we need to be able to fetch embedd-setups for different OSes.
        ID=$OS_OVERRIDE
    elif test -f /etc/os-release; then
        ID=`grep ^ID= /etc/os-release | cut -d= -f2`
    else
        ID=`uname -s`
    fi

    prepare_fetch_and_unpack

    case "$ID" in
        arch)
            install_deps_arch
            ;;
        fedora)
            install_deps_fedora
            ;;
        ubuntu|neon|debian)
            install_deps_ubuntu
            ;;
        Darwin)
            install_deps_darwin
            ;;
        FreeBSD)
            install_deps_FreeBSD
            ;;
        *)
            fetch_and_unpack_Catch2
            fetch_and_unpack_fmtlib
            fetch_and_unpack_yaml_cpp
            echo "OS $ID not supported."
            echo "Dependencies were fetch manually and most likely libunicode will compile."
            ;;
    esac
}

main $*
