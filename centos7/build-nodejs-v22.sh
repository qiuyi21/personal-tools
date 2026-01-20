#!/bin/bash -e

# echo "Installing uv"
# curl -LsSf https://astral.sh/uv/install.sh | sh
if ! command -v uv >/dev/null 2>&1; then
  echo "Please install the uv tool from https://github.com/astral-sh/uv"
  exit 1
fi

OSVER=$(awk '{print $4}' /etc/redhat-release)
if [ -z "$OSVER" ]; then
  echo "Unknown OS version from /etc/redhat-release"
  exit 1
fi
[ "$OSVER" != 7.9.2009 ] && SUF_NAME="-vault"

cat <<EOF >/etc/yum.repos.d/centos.repo
[centos]
name=centos
baseurl=https://mirrors.aliyun.com/centos${SUF_NAME}/$OSVER/os/\$basearch/
enabled=1
priority=10
gpgcheck=0
sslverify=0

[centos-updates]
name=centos-updates
baseurl=https://mirrors.aliyun.com/centos${SUF_NAME}/$OSVER/updates/\$basearch/
enabled=1
priority=10
gpgcheck=0
sslverify=0

[centosplus]
name=centosplus
baseurl=https://mirrors.aliyun.com/centos${SUF_NAME}/$OSVER/centosplus/\$basearch/
enabled=1
priority=10
gpgcheck=0
sslverify=0

[centos-extras]
name=centos-extras
baseurl=https://mirrors.aliyun.com/centos${SUF_NAME}/$OSVER/extras/\$basearch/
enabled=1
priority=10
gpgcheck=0
sslverify=0

[centos-sclo-sclo]
name=CentOS-7 - SCLo sclo
baseurl=https://mirrors.aliyun.com/centos/7/sclo/\$basearch/rh/
enabled=1
gpgcheck=0
sslverify=0

[epel]
name=epel7
baseurl=https://mirrors.aliyun.com/epel/7/\$basearch/
enabled=1
priority=20
gpgcheck=0
sslverify=0
EOF

yum makecache fast
yum install -y yum-plugin-priorities
yum install -y devtoolset-11 curl jq unzip xz patch

NODE_VERSION=v22.22.0
URLS=(
  https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION.tar.xz
  https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-x64.tar.xz
)
for URL in "${URLS[@]}"; do
  FILENAME=$(basename "$URL")
  echo "Downloading $URL"
  curl -k -C - -L -o "$FILENAME" "$URL"
done

echo "Preparing python3.8 venv"
export UV_DEFAULT_INDEX="https://mirrors.aliyun.com/pypi/simple/"
uv venv --python python3.8 .venv
source .venv/bin/activate

echo "Preparing node-$NODE_VERSION source"
tar -Jxf node-$NODE_VERSION.tar.xz
cd node-$NODE_VERSION

# Apply patch
cat <<EOF >/tmp/node.patch
diff -rNu a/deps/cares/src/lib/util/ares_rand.c b/deps/cares/src/lib/util/ares_rand.c
--- a/deps/cares/src/lib/util/ares_rand.c	2026-01-12 22:55:24.000000000 +0000
+++ b/deps/cares/src/lib/util/ares_rand.c	2026-01-17 06:15:51.984904089 +0000
@@ -34,7 +34,92 @@
 #endif
 
 #ifdef HAVE_SYS_RANDOM_H
-#  include <sys/random.h>
+
+#include <sys/syscall.h>
+#include <fcntl.h>
+
+#ifndef SYS_getrandom
+    #if defined(__x86_64__)
+        #define SYS_getrandom 318
+    #elif defined(__i386__)
+        #define SYS_getrandom 355
+    #elif defined(__aarch64__)
+        #define SYS_getrandom 278
+    #elif defined(__arm__)
+        #define SYS_getrandom 384
+    #else
+        #error "SYS_getrandom is not defined in the current architecture. Please refer to the syscall table to add the definition."
+    #endif
+#endif
+
+#ifndef GRND_NONBLOCK
+    #define GRND_NONBLOCK 0x0001
+#endif
+#ifndef GRND_RANDOM
+    #define GRND_RANDOM 0x0002
+#endif
+
+static ssize_t getrandom_fallback(void *buf, size_t buflen, unsigned int flags) {
+    const char *source = "/dev/urandom";
+    int open_flags = O_RDONLY;
+
+    if (flags & GRND_RANDOM) source = "/dev/random";
+
+    if (flags & GRND_NONBLOCK) open_flags |= O_NONBLOCK;
+
+    int fd = open(source, open_flags);
+    if (fd < 0) return -1;
+
+    size_t total_read = 0;
+    ssize_t ret;
+    char *ptr = (char *)buf;
+
+    while (total_read < buflen) {
+        ret = read(fd, ptr + total_read, buflen - total_read);
+        if (ret > 0) {
+            total_read += ret;
+        } else if (ret == 0) {
+            break;
+        } else {
+            if (errno == EINTR) continue;
+            if (total_read == 0) {
+                close(fd);
+                return -1;
+            }
+            break;
+        }
+    }
+
+    close(fd);
+    return total_read;
+}
+
+static volatile int g_getrandom_support = 0;
+
+static inline ssize_t getrandom(void *buf, size_t buflen, unsigned int flags) {
+    int support = __atomic_load_n(&g_getrandom_support, __ATOMIC_RELAXED);
+
+    if (support == 1) {
+        return syscall(SYS_getrandom, buf, buflen, flags);
+    } else if (support == -1) {
+        return getrandom_fallback(buf, buflen, flags);
+    }
+
+    long ret = syscall(SYS_getrandom, buf, buflen, flags);
+
+    if (ret == -1 && errno == ENOSYS) {
+        int new_state = -1;
+        __atomic_store_n(&g_getrandom_support, new_state, __ATOMIC_RELAXED);
+        return getrandom_fallback(buf, buflen, flags);
+    }
+
+    if (g_getrandom_support == 0) {
+        int new_state = 1;
+        __atomic_store_n(&g_getrandom_support, new_state, __ATOMIC_RELAXED);
+    }
+    return ret;
+}
+
 #endif
 
 
diff -rNu a/deps/v8/src/compiler/wasm-compiler.cc b/deps/v8/src/compiler/wasm-compiler.cc
--- a/deps/v8/src/compiler/wasm-compiler.cc	2026-01-12 22:55:26.000000000 +0000
+++ b/deps/v8/src/compiler/wasm-compiler.cc	2026-01-17 07:43:52.950158605 +0000
@@ -8613,11 +8613,13 @@
                  '-');
 
   auto compile_with_turboshaft = [&]() {
+    auto ci = wasm::WrapperCompilationInfo{.code_kind = CodeKind::WASM_TO_JS_FUNCTION};
+    ci.import_info.import_kind = kind;
+    ci.import_info.expected_arity = expected_arity;
+    ci.import_info.suspend = suspend;
     return Pipeline::GenerateCodeForWasmNativeStubFromTurboshaft(
         env->module, sig,
-        wasm::WrapperCompilationInfo{
-            .code_kind = CodeKind::WASM_TO_JS_FUNCTION,
-            .import_info = {kind, expected_arity, suspend}},
+        ci,
         func_name, WasmStubAssemblerOptions(), nullptr);
   };
   auto compile_with_turbofan = [&]() {
@@ -8774,12 +8776,14 @@
       base::VectorOf(name_buffer.get(), kMaxNameLen) + kNamePrefixLen, sig);
 
   auto compile_with_turboshaft = [&]() {
+    auto ci = wasm::WrapperCompilationInfo{.code_kind = CodeKind::WASM_TO_JS_FUNCTION};
+    ci.import_info.import_kind = kind;
+    ci.import_info.expected_arity = expected_arity;
+    ci.import_info.suspend = suspend;
     std::unique_ptr<turboshaft::TurboshaftCompilationJob> job =
         Pipeline::NewWasmTurboshaftWrapperCompilationJob(
             isolate, sig,
-            wasm::WrapperCompilationInfo{
-                .code_kind = CodeKind::WASM_TO_JS_FUNCTION,
-                .import_info = {kind, expected_arity, suspend}},
+            ci,
             nullptr, std::move(name_buffer), WasmAssemblerOptions());
 
     // Compile the wrapper
EOF

patch -p1 </tmp/node.patch
rm -f /tmp/node.patch

source /opt/rh/devtoolset-11/enable

echo "Building node-$NODE_VERSION"
python3 configure.py --verbose --enable-static --disable-shared --enable-lto --with-intl=full-icu --download=all
make -j8

cd ..
NODE_REL=node-$NODE_VERSION-el7-x64
rm -rf $NODE_REL
mkdir $NODE_REL
echo "Extracting node-$NODE_VERSION-linux-x64.tar.xz"
tar -Jxf node-$NODE_VERSION-linux-x64.tar.xz -C $NODE_REL --strip-components=1 --no-same-owner
install -s node-$NODE_VERSION/out/Release/node $NODE_REL/bin/
echo $NODE_VERSION >$NODE_REL/VERSION

echo "Packaging $NODE_REL"
tar -zcf $NODE_REL.tar.gz $NODE_REL
rm -rf $NODE_REL

echo "SUCCESS"
