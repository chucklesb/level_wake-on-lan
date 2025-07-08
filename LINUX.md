# Linux support
One goal of this project was to ensure cross-platform support. To that end, the old `Get-MacAddress.ps1` script has been retired. In its place is a much simpler [osquery script](src/get-mac-address.sql) that handles MAC address discovery on both Windows and Linux.

For the Linux implementation, we needed a way to send the WoL magic packet. While Bash offers some clever networking pseudo-devices like `/dev/udp`, they proved unreliable for our needs. I ultimately chose `socat`, a standard and powerful networking utility.

Since Level RMM does not yet natively manage Linux packages, I opted to build statically-linked `socat` binary from source. This creates a single, portable executable that has no external dependencies, allowing it to run on nearly any (x86_64) Linux system you throw it on.

> [!NOTE]
> IMPORTANT: There is a known issue where Level's "Download file" action appends a period to filenames that do not have an extension (e.g., `socat` becomes `socat.`). I recommend renaming the compiled binary to `socat.bin` before uploading it to Level.

## Socat Build Instructions
Follow these instructions to build a statically-linked `socat` binary on Ubuntu/Debian. The binary will have minimal features enabled to reduce build complexity, size, and attack surface.

### Update packages and install build dependencies
```
sudo apt update && sudo apt upgrade
sudo apt install build-essential musl-tools -y
```

### Download and extract socat source tarball
The latest socat source package as of this writing is `1.8.0.3`. You can find the most recent release [here](http://www.dest-unreach.org/socat/download/).
```
socat_version="1.8.0.3"
wget http://www.dest-unreach.org/socat/download/socat-${socat_version}.tar.gz
tar xvf socat-${socat_version}.tar.gz
cd socat-${socat_version}/
```

### Configure and build
These build options accomplish a few things:
 - Enable binary optimizations
 - Strip debug symbols
 - Build and link static binaries/libraries
 - Disable any `socat` features that aren't conducive to sending our Wake-On-LAN UDP packet
```
CC=musl-gcc CFLAGS="-Os -s -static" LDFLAGS="-static" ./configure \
  --disable-openssl \
  --disable-readline \
  --disable-libwrap \
  --disable-sycls \
  --disable-filan \
  --disable-stats \
  --disable-tcp \
  --disable-sctp \
  --disable-dccp \
  --disable-udplite \
  --disable-exec \
  --disable-system \
  --disable-shell \
  --disable-pty \
  --disable-socks4 \
  --disable-socks4a \
  --disable-socks5 \
  --disable-proxy \
  --disable-pipe \
  --disable-socketpair \
  --disable-termios \
  --disable-gopen \
  --disable-creat \
  --disable-file \
  --disable-fdnum \
  --disable-fs \
  --disable-posixmq \
  --disable-unix \
  --disable-abstract-unixsocket \
  --disable-listen \
  --disable-retry \
  --disable-tun \
  --disable-vsock \
  --disable-namespaces
make
```

### Verify
The commands below can be used to verify that we have built a static binary with minimal features enabled.
```
$ ls -l ./socat
-rwxr-xr-x 1 user user 314288 Jul  8 11:19 ./socat
$ file ./socat
./socat: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, stripped
$ ldd ./socat
        not a dynamic executable
$ readelf -d ./socat

There is no dynamic section in this file.
$ ./socat -V
socat by Gerhard Rieger and contributors - see www.dest-unreach.org
socat version 1.8.0.3 on Jul  8 2025 11:19:02
   running on Linux version #1 SMP PREEMPT_DYNAMIC Thu Jun  5 18:30:46 UTC 2025, release 6.6.87.2-microsoft-standard-WSL2, machine x86_64 features:
  #define WITH_HELP 1
  #undef WITH_STATS
  #define WITH_STDIO 1
  #undef WITH_FDNUM
  #undef WITH_FILE
  #undef WITH_CREAT
  #undef WITH_GOPEN
  #undef WITH_TERMIOS
  #undef WITH_PIPE
  #undef WITH_SOCKETPAIR
  #undef WITH_UNIX
  #undef WITH_ABSTRACT_UNIXSOCKET
  #define WITH_IP4 1
  #define WITH_IP6 1
  #define WITH_RAWIP 1
  #define WITH_GENERICSOCKET 1
  #undef WITH_INTERFACE
  #undef WITH_TCP
  #define WITH_UDP 1
  #undef WITH_SCTP
  #undef WITH_DCCP
  #undef WITH_UDPLITE
  #undef WITH_LISTEN
  #undef WITH_POSIXMQ
  #undef WITH_SOCKS4
  #undef WITH_SOCKS4A
  #undef WITH_SOCKS5
  #undef WITH_VSOCK
  #undef WITH_NAMESPACES
  #undef WITH_PROXY
  #undef WITH_SYSTEM
  #undef WITH_SHELL
  #undef WITH_EXEC
  #undef WITH_READLINE
  #undef WITH_TUN
  #undef WITH_PTY
  #undef WITH_OPENSSL
  #undef WITH_FIPS
  #undef WITH_LIBWRAP
  #undef WITH_SYCLS
  #undef WITH_FILAN
  #undef WITH_RETRY
  #undef WITH_DEVTESTS
  #define WITH_MSGLEVEL 0 /*debug*/
  #define WITH_DEFAULT_IPV 4
```