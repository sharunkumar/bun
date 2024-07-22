#!/bin/sh
# Script to build Bun from source.
# Uses `sh` instead of `bash`, so it can run in minimal Docker images.

main() {
  os=$(detect_os)
  arch=$(detect_arch)
  target="$os-$arch"

  scripts_dir=$(path $(cd -- "$(dirname -- "$0")" && pwd -P))
  cwd=$(path $(dirname "$scripts_dir"))
  src_dir=$(path "$cwd" "src")
  src_deps_dir=$(path "$src_dir" "deps")
  build_dir=$(path "$cwd" "build")
  build_deps_dir=$(path "$build_dir" "bun-deps")

  clean="0"
  jobs=$(detect_jobs)
  verbose="0"
  ci=$(detect_ci)
  cpu=$(default_cpu)
  baseline="0"
  type="release"
  version=$(default_version)
  revision=$(default_revision)
  canary="0"
  assertions="0"
  lto="1"
  valgrind="0"
  llvm_version=$(default_llvm_version)
  macos_version=$(default_macos_version)
  ar=$(default_ar)
  ld=$(default_ld)
  ccache=$(default_ccache)
  cc_version=$(default_cc_version)
  cc=$(default_cc)
  cxx_version=$(default_cxx_version)
  cxx=$(default_cxx)
  zig_version=$(default_zig_version)
  zig_optimize=$(default_zig_optimize)
  zig=$(default_zig)
  bun_version=$(default_bun_version)
  bun=$(default_bun)

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) help; exit 0 ;;
      --target) target="$2"; shift ;;
      --os) target="$2"; shift ;;
      --arch) target="$target-$2"; shift ;;
      --artifact) artifact="$2"; shift ;;
      --clean) clean="1"; shift ;;
      -j | --jobs) jobs="$2"; shift ;;
      --ci) ci="1"; shift ;;
      --verbose) verbose="1"; shift ;;
      --os) os="$2"; shift ;;
      --arch) arch="$2"; shift ;;
      --cpu) cpu="$2"; shift ;;
      --baseline) baseline="1"; cpu="nehalem"; shift ;;
      --version) version="$2"; shift ;;
      --revision) revision="$2"; shift ;;
      --canary) canary="$(default_canary)"; shift ;;
      --debug) type="debug"; shift ;;
      --assertions) assertions="1"; shift ;;
      --lto) lto="1"; shift ;;
      --no-lto) lto="0"; shift ;;
      --valgrind) valgrind="1"; shift ;;
      --llvm-version) llvm_version="$2"; shift ;;
      --macos-version) macos_version="$2"; shift ;;
      --cc-version) cc_version="$2"; shift ;;
      --cxx-version) cxx_version="$2"; shift ;;
      --cc) cc="$2"; shift ;;
      --cxx) cxx="$2"; shift ;;
      --ar) ar="$2"; shift ;;
      --ld) ld="$2"; shift ;;
      --ccache) ccache="1"; shift ;;
      --zig-version) zig_version="$2"; shift ;;
      --zig-optimize) zig_optimize="$2"; shift ;;
      --zig) zig="$2"; shift ;;
      --bun-version) bun_version="$2"; shift ;;
      --bun) bun="$2"; shift ;;
      --cwd) cwd="$2"; shift ;;
      *) shift ;;
    esac
  done

  case "$artifact" in
    bun) build_bun ;;
    bun*cpp | cpp) build_bun "cpp" ;;
    bun*zig | zig) build_bun "zig" ;;
    bun*link | link) build_bun "link" ;;
    bun*deps | deps) build_deps ;;
    boring*ssl) build_boringssl ;;
    c*ares) build_cares ;;
    lib*archive) build_libarchive ;;
    libuv) build_libuv ;;
    lol*html) build_lolhtml ;;
    ls*hpack) build_lshpack ;;
    mimalloc) build_mimalloc ;;
    tinycc) build_tinycc ;;
    zlib) build_zlib ;;
    zstd) build_zstd ;;
    *)
      if [ "$clean" = "1" ]; then
        clean_deps
      fi
    ;;
  esac
}

run_command() {
  local cmd="$1"
  shift

  set -x
  $cmd $@
  { set +x; } 2>/dev/null
}

path() {
  string="$1"
  for arg in "${@:2}"; do
    if [ -n "$arg" ]; then
      string="$string/$arg"
    fi
  done
  if [ -n "$string" ] && [ "$os" = "windows" ]; then
    cygpath -w "$string" | sed 's/\\/\//g'
  else
    echo "$string"
  fi
}

which() {
  if [ "$os" = "windows" ] && command -v "$1" >/dev/null 2>&1; then
    # On Windows, cygwin will transform to path to /cygdrive which
    # causes problems with cmake and other tools.
    cygpath -w $(command -v "$1") | sed 's/\\/\//g'
  else
    command -v "$1"
  fi
}

exists() {
  which "$1" >/dev/null 2>&1
}

require() {
  if ! exists "$1"; then
    error "command is required to build bun: $1"
  fi
  which "$1"
}

is_interactive() {
  if exists tty && tty -s >/dev/null 2>&1; then
    print "1"
  fi
}

ansi_color() {
  case "$1" in
    reset)  printf "\033[0m" ;;
    bold)   printf "\033[1m" ;;
    dim)    printf "\033[2m" ;;
    red)    printf "\033[31m" ;;
    green)  printf "\033[32m" ;;
    yellow) printf "\033[33m" ;;
    pink)   printf "\033[35m" ;;
    cyan)   printf "\033[36m" ;;
    *) ;;
  esac
}

print() {
  printf "%s " "$@" | awk '{$1=$1};1'
}

pretty() {
  string="$1"
  for color in reset bold dim red green yellow pink cyan; do
    string=$(print "$string" | sed -e "s/{$color}/$(ansi_color "$color")/g")
  done
  print "$string"
}

pretty_ln() {
  pretty "$1"
  printf "\n"
}

warn() {
  pretty_ln "{yellow}{bold}warn{reset}: $*{reset}" >&2
}

error() {
  pretty_ln "{red}{bold}error{reset}: $*{reset}" >&2
  exit 1
}

prompt() {
  if is_interactive >/dev/null; then
    pretty "$1 {dim}[y/n]{reset} "
    read -r
    case "$REPLY" in
      [yY]) ;;
      *) exit 1 ;;
    esac
  fi
}

lowercase() {
  tr '[:upper:]' '[:lower:]'
}

oneline() {
  head -n 1
}

regex() {
  # There are two versions of grep: GNU and BSD.
  # GNU grep supports -P, BSD grep supports -E.
  if grep --version | grep -q BSD 2>/dev/null; then
    grep -Eo "$1"
  else
    grep -Po "$1"
  fi
}

semver() {
  regex '[0-9]+\.[0-9]\.*[0-9]*' | oneline
}

detect_os() {
  local os=$(uname -s)
  case "$os" in
    Linux)                    print "linux" ;;
    Darwin)                   print "darwin" ;;
    MINGW* | MSYS* | CYGWIN*) print "windows" ;;
    *) error "unsupported operating system: $os" ;;
  esac
}

detect_arch() {
  local arch=$(uname -m)
  case "$arch" in
    x86_64 | amd64)  print "x64" ;;
    aarch64 | arm64) print "aarch64" ;;
    *) error "unsupported architecture: $arch" ;;
  esac
}

detect_ci() {
  if [ "$CI" = "true" ] || [ "$CI" = "1" ]; then
    print "1"
  else
    print "0"
  fi
}

detect_jobs() {
  if exists nproc; then
    nproc
  elif exists sysctl; then
    sysctl -n "hw.ncpu"
  else
    print "1"
  fi
}

default_cpu() {
  case "$arch" in
    x64)     print "haswell" ;;
    aarch64) print "native" ;;
    *) error "unsupported architecture: $arch" ;;
  esac
}

default_llvm_version() {
  print "16"
}

default_macos_version() {
  print "13.0"
}

default_cc_version() {
  print "17"
}

default_cc_flags() {
  local flags=(
    -fuse-ld="$ld"
  )

  if [ "$os" = "windows" ]; then
    flags+=(
      /O2
      /Z7
      /MT
      /Ob2
      /DNDEBUG
      /U_DLL
    )
  else
    flags+=(
      -O3
      -fno-exceptions
      -fvisibility=hidden
      -fvisibility-inlines-hidden
      -mno-omit-leaf-frame-pointer
      -fno-omit-frame-pointer
      -fno-asynchronous-unwind-tables
      -fno-unwind-tables
      -faddrsig
      -std="c$cc_version"
    )
  fi

  if [ "$os" = "linux" ]; then
    flags+=(
      -ffunction-sections
      -fdata-sections
    )
  elif [ "$os" = "darwin" ]; then
    flags+=(
      -mmacosx-version-min="$macos_version"
      -D__DARWIN_NON_CANCELABLE=1
    )
  fi

  if [ "$arch" = "aarch64" ]; then
    if [ "$os" = "linux" ]; then
      flags+=(
        -march=armv8-a+crc
        -mtune=ampere1
      )
    elif [ "$os" = "darwin" ]; then
      flags+=(-mcpu=apple-m1)
    fi
  else
    flags+=(-march="$cpu")
  fi

  if [ "$lto" = "1" ]; then
    flags+=(-flto)
    if [ "$os" = "windows" ]; then
      flags+=(
        -Xclang
        -emit-llvm-bc
      )
    fi
  fi

  if [ "$os" != "windows" ]; then
    if [ -n "$FORCE_PIC" ]; then
      flags+=(-fpic)
    else
      flags+=(-fno-pie -fno-pic)
    fi
  fi

  print "${flags[@]}"
}

default_cc() {
  if [ "$os" = "windows" ]; then
    which "clang-cl"
  else
    which "clang-$llvm_version" || which "clang" || which "cc"
  fi
}

default_cxx_version() {
  print "20"
}

default_cxx_flags() {
  local flags=$(default_cc_flags)

  flags+=(
    -fno-rtti
    -std="c++$cxx_version"
  )
  
  print "${flags[@]}"
}

default_cxx() {
  if [ "$os" = "windows" ]; then
    which "clang-cl"
  else
    which "clang++-$llvm_version" || which "clang++" || which "c++"
  fi
}

default_ar() {
  which "llvm-ar-$llvm_version" || which "llvm-ar" || which "ar"
}

default_ld_flags() {
  if [ "$os" = "linux" ]; then
    print "-Wl,-z,norelro"
  fi
}

default_ld() {
  if [ "$os" = "darwin" ]; then
    which "ld64.lld" || which "ld"
  elif [ "$os" = "linux" ]; then
    which "ld.lld" || which "ld"
  elif [ "$os" = "windows" ]; then
    which "lld-link" || which "ld"
  fi
}

default_ccache() {
  which "ccache" || which "sccache"
}

default_zig_version() {
  local path="$cwd/build.zig"

  if [ -f "$path" ]; then
    grep 'recommended_zig_version = "' "$path" | cut -d '"' -f2
  else
    warn "{dim}--zig-version{reset} should be defined due to missing file: {dim}$path{reset}" >&2
    latest_zig_version
  fi
}

latest_zig_version() {
  curl -fsSL https://ziglang.org/download/index.json | jq -r .master.version
}

default_zig_optimize() {
  case "$target" in
    windows*) print "ReleaseSafe" ;;
    *) print "ReleaseFast" ;;
  esac
}

default_zig() {
  which zig
}

default_bun_version() {
  local path="$cwd/LATEST"

  if [ -f "$path" ]; then
    cat "$path"
  else
    warn "{dim}--bun-version{reset} should be defined due to missing file: {dim}$path{reset}" >&2
    latest_bun_version
  fi
}

latest_bun_version() {
  curl -fsSL https://raw.githubusercontent.com/oven-sh/bun/main/LATEST
}

default_bun() {
  which bun
}

default_version() {
  local path="$cwd/LATEST"

  if [ -f "$path" ]; then
    cat "$path"
  else
    warn "{dim}--version{reset} should be defined due to missing file: {dim}$path{reset}" >&2
    print "0.0.0"
  fi
}

default_revision() {
  if $(cd "$cwd" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    local revision=$(cd "$cwd" && git rev-parse HEAD)
    print "$revision"
  else
    warn "--revision should be defined due missing git repository" >&2
    print "unknown"
  fi
}

default_canary() {
  local ahead_by=$(curl -sL "https://api.github.com/repos/oven-sh/bun/compare/bun-v$version...$revision" | jq -r ".ahead_by")
  if [ "$ahead_by" == "null" ]; then
    print "1"
  else
    print "$ahead_by"
  fi
}

help() {
  pretty_ln "Script to build {pink}{bold}Bun {reset}from source.

Options:
  {cyan}-h{reset}, {cyan}--help{reset}               Print this help message and exit{reset}
  {cyan}--target{reset} {dim}[value]{reset}       Specify the target to build{reset}                        {dim}(default: {green}$target{reset}{dim}){reset}
  {cyan}--artifact{reset} {dim}[value]{reset}       Specify the artifact to build{reset}                        {dim}(default: {green}$artifact{reset}{dim}){reset}
  {cyan}--clean{reset}                  Specify if the build should be cleaned{reset}               {dim}(default: {yellow}$clean{reset}{dim}){reset}
  {cyan}-j{reset}, {cyan}--jobs{reset} {dim}[value]{reset}       Specify the number of jobs to run in parallel{reset}        {dim}(default: {yellow}$jobs{reset}{dim}){reset}
  {cyan}--ci{reset}                     Specify if this is a CI build{reset}                        {dim}(default: {yellow}$ci{reset}{dim}){reset}
  {cyan}--verbose{reset}                Specify if the build should be verbose{reset}               {dim}(default: {yellow}$verbose{reset}{dim}){reset}

  {cyan}--os{reset} {dim}[value]{reset}             Specify the operating system to target               {dim}(default: {green}$os{reset}{dim}){reset}
  {cyan}--arch{reset} {dim}[value]{reset}           Specify the architecture to target                   {dim}(default: {green}$arch{reset}{dim}){reset}
  {cyan}--cpu{reset} {dim}[value]{reset}            Specify the CPU target to build{reset}                      {dim}(default: {green}$cpu{reset}{dim}){reset}
  {cyan}--baseline{reset}               Specify if this is a baseline build{reset}                  {dim}(default: {yellow}$baseline{reset}{dim}){reset}

  {cyan}--debug{reset}, {cyan}--release{reset}       Specify if this is a debug or release build{reset}          {dim}(default: {green}$type{reset}{dim}){reset}
  {cyan}--version{reset} {dim}[semver]{reset}       Specify the version in {dim}bun --version{reset}                 {dim}(default: {yellow}$version{reset}{dim}){reset}
  {cyan}--revision{reset} {dim}[sha]{reset}         Specify the git commit in {dim}bun --revision{reset}             {dim}(default: {green}$revision{reset}{dim}){reset}
  {cyan}--canary{reset} {dim}[number]{reset}        Specify the build number of the canary build{reset}         {dim}(default: {yellow}$canary{reset}{dim}){reset}
  {cyan}--assertions{reset}             Specify if assertions should be enabled{reset}              {dim}(default: {yellow}$assertions{reset}{dim}){reset}
  {cyan}--lto{reset}, {cyan}--no-lto{reset}          Specify if link-time optimization should be enabled{reset}  {dim}(default: {yellow}$lto{reset}{dim}){reset}
  {cyan}--valgrind{reset}             Specify if valgrind should be enabled (Linux only){reset}              {dim}(default: {yellow}$valgrind{reset}{dim}){reset}

  {cyan}--llvm-version{reset} {dim}[semver]{reset}  Specify the LLVM version to use{reset}                      {dim}(default: {yellow}$llvm_version{reset}{dim}){reset}
  {cyan}--macos-version{reset} {dim}[semver]{reset} Specify the minimum macOS version to target{reset}          {dim}(default: {yellow}$macos_version{reset}{dim}){reset}
  {cyan}--cc-version{reset} {dim}[number]{reset}    Specify the C standard to use{reset}                        {dim}(default: {yellow}$cc_version{reset}{dim}){reset}
  {cyan}--cxx-version{reset} {dim}[number]{reset}   Specify the C++ standard to use{reset}                      {dim}(default: {yellow}$cxx_version{reset}{dim}){reset}
  {cyan}--cc{reset} {dim}[path]{reset}              Specify the C compiler to use{reset}                        {dim}(default: {green}$cc{reset}{dim}){reset}
  {cyan}--cxx{reset} {dim}[path]{reset}             Specify the C++ compiler to use{reset}                      {dim}(default: {green}$cxx{reset}{dim}){reset}
  {cyan}--ar{reset} {dim}[path]{reset}              Specify the archiver to use{reset}                          {dim}(default: {green}$ar{reset}{dim}){reset}
  {cyan}--ld{reset} {dim}[path]{reset}              Specify the linker to use{reset}                            {dim}(default: {green}$ld{reset}{dim}){reset}

  {cyan}--zig-version{reset} {dim}[semver]{reset}   Specify the zig version to use{reset}                       {dim}(default: {yellow}$zig_version{reset}{dim}){reset}
  {cyan}--zig-optimize{reset} {dim}[value]{reset}   Specify the zig optimization level{reset}                    {dim}(default: {yellow}$zig_optimize{reset}{dim}){reset}
  {cyan}--zig{reset} {dim}[path]{reset}             Specify the zig executable to use{reset}                    {dim}(default: {green}$zig{reset}{dim}){reset}

  {cyan}--bun-version{reset} {dim}[semver]{reset}   Specify the bun version to use{reset}                       {dim}(default: {yellow}$bun_version{reset}{dim}){reset}
  {cyan}--bun{reset} {dim}[path]{reset}             Specify the bun executable to use{reset}                    {dim}(default: {green}$bun{reset}{dim}){reset}
"
}

clean() {
  if [ "$clean" = "1" ]; then
    run_command git clean -fdx "$@"
  fi
}

copy() {
  if [ ! -f "$1" ]; then
    error "file not found: $1"
  fi
  if [ ! -d "$2" ]; then
    mkdir -p "$(dirname "$2")"
  fi
  cp "$1" "$2"
  pretty_ln "{dim}-> {reset}{green}$2{reset}" 2>&1
}

cmake_configure() {
  # case "$@" in
  #   *--pic*) export FORCE_PIC="1"; shift ;;
  #   *) shift ;;
  # esac

  export CFLAGS="$(default_cc_flags)"
  export CXXFLAGS="$(default_cxx_flags)"
  export LDFLAGS="$(default_ld_flags)"

  export CMAKE_FLAGS=(
    -GNinja
    -DCMAKE_BUILD_PARALLEL_LEVEL="$jobs"
    -DCMAKE_C_STANDARD="$cc_version"
    -DCMAKE_CXX_STANDARD="$cxx_version"
    -DCMAKE_C_STANDARD_REQUIRED=ON
    -DCMAKE_CXX_STANDARD_REQUIRED=ON
    -DCMAKE_C_COMPILER="$cc"
    -DCMAKE_CXX_COMPILER="$cxx"
    '-DCMAKE_C_FLAGS=$CFLAGS'
    '-DCMAKE_CXX_FLAGS=$CXXFLAGS'
  )

  if [ "$type" = "debug" ]; then
    CMAKE_FLAGS+=(-DCMAKE_BUILD_TYPE=Debug)
  else
    CMAKE_FLAGS+=(-DCMAKE_BUILD_TYPE=Release)
  fi

  if [ -n "$ccache" ]; then
    CMAKE_FLAGS+=(
      -DCMAKE_C_COMPILER_LAUNCHER="$ccache"
      -DCMAKE_CXX_COMPILER_LAUNCHER="$ccache"
    )
  fi

  if [ "$os" = "linux" ]; then
    CMAKE_FLAGS+=(-DCMAKE_CXX_EXTENSIONS=ON)
  elif [ "$os" = "darwin" ]; then
    CMAKE_FLAGS+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$macos_version")
  elif [ "$os" = "windows" ]; then
    CMAKE_FLAGS+=(-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded)
  fi

  if [ "$verbose" = "1" ]; then
    CMAKE_FLAGS+=(-DCMAKE_VERBOSE_MAKEFILE=ON)
  fi

  run_command cmake -S "$1" -B "$2" ${CMAKE_FLAGS[@]} ${@:3}
}

cmake_build() {
  local flags=(--build $@)

  if [ "$type" = "debug" ]; then
    flags+=(--config Debug)
  else
    flags+=(--config Release)
  fi

  run_command cmake ${flags[@]}
}

rust_target() {
  case "$target" in
    windows-x64) print "x86_64-pc-windows-msvc" ;;
    windows-aarch64) print "aarch64-pc-windows-msvc" ;;
    linux-x64) print "x86_64-unknown-linux-gnu" ;;
    linux-aarch64) print "aarch64-unknown-linux-gnu" ;;
    darwin-x64) print "x86_64-apple-darwin" ;;
    darwin-aarch64) print "aarch64-apple-darwin" ;;
    *) error "unsupported cargo target: $target" ;;
  esac
}

cargo_build() {
  local flags=(
    --manifest-path="$1/Cargo.toml"
    --target-dir="$2"
    --target="$(rust_target)"
    --jobs="$jobs"
    ${@:3}
  )

  if [ "$type" != "debug" ]; then
    flags+=(--release)
  fi

  if [ "$verbose" = "1" ]; then
    flags+=(--verbose)
  fi

  run_command cargo build ${flags[@]}
}

zig_target() {
  case "$target" in
    windows-x64) print "x86_64-windows-msv" ;;
    windows-aarch64) print "aarch64-windows-msv" ;;
    linux-x64) print "x86_64-linux-gnu" ;;
    linux-aarch64) print "aarch64-linux-gnu" ;;
    darwin-x64) print "x86_64-macos-none" ;;
    darwin-aarch64) print "aarch64-macos-none" ;;
    *) error "unsupported zig target: $target" ;;
  esac
}

ninja_build() {
  local flags=(
    -v
    -j "$jobs"
  )

  run_command ninja ${flags[@]} $@
}

if_windows() {
  if [ "$os" = "windows" ]; then
    print "$1"
  else
    print "$2"
  fi
}

list_deps() {
  local deps=(
    boringssl
    cares
    libarchive
    lolhtml
    lshpack
    mimalloc
    tinycc
    zlib
    zstd
    lshpack
  )

  if [ "$os" = "windows" ]; then
    deps+=(libuv)
  fi

  print "${deps[@]}"
}

clean_deps() {
  for dep in $(list_deps); do
    clean "$(src_$dep)"
  done
}

build_deps() {
  for dep in $(list_deps); do
    build_$dep
  done
}

src_boringssl() {
  path "$src_deps_dir" "boringssl"
}

build_boringssl() {
  local src=$(src_boringssl)
  local dst=$(path "$build_dir" "boringssl")

  clean $src $dst
  cmake_configure $src $dst
  cmake_build $dst \
    --target crypto \
    --target ssl \
    --target decrepit
  
  local artifacts=(
    $(if_windows "crypto.lib" "libcrypto.a")
    $(if_windows "ssl.lib" "libssl.a")
    $(if_windows "decrepit.lib" "libdecrepit.a")
  )

  for artifact in "${artifacts[@]}"; do
    copy $(path "$dst" "$artifact") $(path "$build_deps_dir" "$artifact")
  done
}

src_cares() {
  path "$src_deps_dir" "c-ares"
}

build_cares() {
  local src=$(src_cares)
  local dst=$(path "$build_dir" "c-ares")

  clean $src $dst
  cmake_configure $src $dst \
    -DCARES_STATIC=ON \
    -DCARES_STATIC_PIC=ON \
    -DCARES_SHARED=OFF
  cmake_build $dst \
    --target c-ares

  local artifact=$(if_windows "cares.lib" "libcares.a")

  copy $(path "$dst" "lib" "$artifact") $(path "$build_deps_dir" "$artifact")
}

src_libarchive() {
  path "$src_deps_dir" "libarchive"
}

build_libarchive() {
  local src=$(src_libarchive)
  local dst=$(path "$build_dir" "libarchive")

  clean $src $dst
  cmake_configure $src $dst \
    -DBUILD_SHARED_LIBS=0 \
    -DENABLE_BZIP2=0 \
    -DENABLE_CAT=0 \
    -DENABLE_EXPAT=0 \
    -DENABLE_ICONV=0 \
    -DENABLE_INSTALL=0 \
    -DENABLE_LIBB2=0 \
    -DENABLE_LibGCC=0 \
    -DENABLE_LIBXML2=0 \
    -DENABLE_LZ4=0 \
    -DENABLE_LZMA=0 \
    -DENABLE_LZO=0 \
    -DENABLE_MBEDTLS=0 \
    -DENABLE_NETTLE=0 \
    -DENABLE_OPENSSL=0 \
    -DENABLE_PCRE2POSIX=0 \
    -DENABLE_PCREPOSIX=0 \
    -DENABLE_TEST=0 \
    -DENABLE_WERROR=0 \
    -DENABLE_ZLIB=0 \
    -DENABLE_ZSTD=0
  cmake_build $dst \
    --target archive_static

  local artifact=$(if_windows "archive.lib" "libarchive.a")

  copy $(path "$dst" "libarchive" "$artifact") $(path "$build_deps_dir" "$artifact")
}

src_libuv() {
  path "$src_deps_dir" "libuv"
}

build_libuv() {
  if [ "$os" != "windows" ]; then
    return
  fi

  local src=$(src_libuv)
  local dst=$(path "$build_dir" "libuv")

  clean $src $dst
  cmake_configure $src $dst \
    "-DCMAKE_C_FLAGS=/DWIN32 /D_WINDOWS -Wno-int-conversion"
  cmake_build $dst

  local artifact="libuv.lib"
  copy $(path "$dst" "$artifact") $(path "$build_deps_dir" "$artifact")
}

src_lolhtml() {
  path "$src_deps_dir" "lol-html"
}

build_lolhtml() {
  local cwd=$(src_lolhtml)
  local src=$(path "$cwd" "c-api")
  local dst=$(path "$build_dir" "lol-html")

  clean $cwd $src $dst
  cargo_build $src $dst

  local target=$(rust_target)
  local artifact=$(if_windows "lolhtml.lib" "liblolhtml.a")
  copy $(path "$dst" "$target" "$type" "$artifact") $(path "$build_deps_dir" "$artifact")
}

src_lshpack() {
  path "$src_deps_dir" "ls-hpack"
}

build_lshpack() {
  local src=$(src_lshpack)
  local dst=$(path "$build_dir" "ls-hpack")

  clean $src $dst
  cmake_configure $src $dst \
    -DLSHPACK_XXH=ON \
    -DSHARED=0
  cmake_build $dst

  local artifact=$(if_windows "ls-hpack.lib" "libls-hpack.a")
  local name=$(if_windows "lshpack.lib" "liblshpack.a")

  copy $(path "$dst" "$artifact") $(path "$build_deps_dir" "$name")
}

src_mimalloc() {
  path "$src_deps_dir" "mimalloc"
}

build_mimalloc() {
  local src=$(src_mimalloc)
  local dst=$(path "$build_dir" "mimalloc")

  local flags=(
    -DMI_SKIP_COLLECT_ON_EXIT=1
    -DMI_BUILD_SHARED=OFF
    -DMI_BUILD_STATIC=ON
    -DMI_BUILD_TESTS=OFF
    -DMI_OSX_ZONE=OFF
    -DMI_OSX_INTERPOSE=OFF
    -DMI_BUILD_OBJECT=ON
    -DMI_USE_CXX=ON
    -DMI_OVERRIDE=OFF
    -DMI_OSX_ZONE=OFF
  )

  if [ "$type" = "debug" ]; then
    flags+=(-DMI_DEBUG_FULL=1)
  fi

  if [ "$valgrind" = "1" ] && [ "$os" = "linux" ]; then
    flags+=(-DMI_TRACK_VALGRIND=ON)
  fi

  clean $src $dst
  cmake_configure $src $dst ${flags[@]}  
  cmake_build $dst

  local artifact=$(if_windows "mimalloc-static.lib" "libmimalloc.a")
  local name=$(if_windows "mimalloc.lib" "libmimalloc.a")

  if [ "$type" = "debug" ]; then
    artifact=$(if_windows "mimalloc-static-debug.lib" "libmimalloc-debug.a")
    name=$(if_windows "mimalloc.lib" "libmimalloc-debug.a")
  fi

  if [ "$valgrind" = "1" ] && [ "$os" = "linux" ]; then
    artifact="libmimalloc-valgrind.a"
  fi

  copy $(path "$dst" "$artifact") $(path "$build_deps_dir" "$name")
  if [ "$os" != "windows" ]; then
    copy $(path "$dst" "CMakeFiles" "mimalloc-obj.dir" "src" "static.c.o") $(path "$build_deps_dir" "$artifact" | sed 's/\.a$/.o/')
  fi
}

src_tinycc() {
  path "$src_deps_dir" "tinycc"
}

build_tinycc() {
  local pwd=$(pwd)
  local src=$(src_tinycc)
  local dst=$(path "$build_dir" "tinycc")

  cd $src

  clean $src $dst
  if [ "$clean" = "1" ]; then
    run_command make clean
  fi

  local configure=$(path "$src" "configure")
  local flags=(
    --enable-static
    --cc="$cc"
    --ar="$ar"
    --config-predefs=yes
    '--extra-cflags="$CFLAGS"'
  )

  if [ "$cpu" != "native" ]; then
    flags+=(--cpu="$cpu")
  fi

  if [ "$type" = "debug" ]; then
    flags+=(--debug)
  fi

  export CFLAGS="$(default_cc_flags)"
  run_command "$configure" "${flags[@]}"
  run_command make -j "$jobs" libz.a

  cd "$pwd"
}

src_zlib() {
  path "$src_deps_dir" "zlib"
}

patch_zlib() {
  if [ "$os" == "windows" ]; then
    # TODO: make a patch upstream to change the line: `#ifdef _MSC_VER`
    # to account for clang-cl, which implements `__builtin_ctzl` and `__builtin_expect`
    run_command git apply "$src_deps_dir/patches/zlib/deflate.h.patch"
  fi
}

build_zlib() {
  local src=$(src_zlib)
  local dst=$(path "$build_dir" "zlib")

  clean $src $dst
  if [ "$clean" = "1" ]; then
    patch_zlib
  fi
  

  cmake_configure $src $dst
  cmake_build $dst

  local artifact=$(if_windows "zlib.lib" "libz.a")

  copy $(path "$dst" "$artifact") $(path "$build_deps_dir" "$artifact")
}

src_zstd() {
  path "$src_deps_dir" "zstd"
}

build_zstd() {
  local src=$(path "$(src_zstd)" "build" "cmake")
  local dst=$(path "$build_dir" "zstd")
  
  clean $src $dst
  cmake_configure $src $dst \
    -DZSTD_BUILD_STATIC=ON
  cmake_build $dst \
    --target libzstd_static

  local artifact=$(if_windows "zstd_static.lib" "libzstd.a")
  local name=$(if_windows "zstd.lib" "libzstd.a")

  copy $(path "$dst" "lib" "$artifact") $(path "$build_deps_dir" "$name")
}

build_bun() {
  local pwd=$(pwd)
  local src="$cwd"

  local dirname="bun-$artifact"
  if [ "$artifact" = "bun" ] || [ "$artifact" = "link" ]; then
    dirname="bun"
  fi
  local dst=$(path "$build_dir" "$dirname")

  local flags=(
    # -DBUN_ZIG_OBJ_DIR="$dst"
    # -DBUN_CPP_ARCHIVE="$dst/bun-cpp-objects.a"
    # -DBUN_DEPS_OUT_DIR="$dst/bun-deps"
    -DNO_CONFIGURE_DEPENDS=1
    -DCPU_TARGET="$cpu"
    -DCANARY="$canary"
    -DBun_VERSION="$version"
    -DLLVM_VERSION="$llvm_version"
    -DGIT_SHA="$revision"
  )

  if [ "$baseline" = "1" ]; then
    flags+=(-USE_BASELINE_BUILD=ON)
  fi

  if [ "$lto" = "1" ]; then
    flags+=(-DUSE_LTO=ON)
  fi

  if [ "$assertions" = "1" ]; then
    flags+=(-DUSE_DEBUG_JSC=ON)
  fi

  if [ "$valgrind" = "1" ] && [ "$os" = "linux" ]; then
    flags+=(-DUSE_VALGRIND=ON)
  fi

  local artifact="$1"
  print "Building $artifact"

  if [ "$artifact" = "cpp" ]; then
    flags+=(-DBUN_CPP_ONLY=1)
  elif [ "$artifact" = "zig" ]; then
    flags+=(
      -DWEBKIT_DIR="omit"
      -DZIG_TARGET="$(zig_target)"
      -DZIG_OPTIMIZE="$zig_optimize"
    )
  elif [ "$artifact" = "link" ]; then
    flags+=(-DBUN_LINK_ONLY=1)
  fi

  clean $src $dst
  cmake_configure $src $dst ${flags[@]}

  cd "$dst"

  if [ "$artifact" = "cpp" ]; then
    run_command sh compile-cpp-only.sh -v -j "$jobs"
  elif [ "$artifact" = "zig" ]; then
    export ONLY_ZIG=1
    ninja_build "$dst/bun-zig.o"
  else
    ninja_build
  fi

  cd "$pwd"
}

main "$@"