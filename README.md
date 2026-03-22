# Loki Password Manager: Android App

![Loki-Android Logo](./Loki-Android.png)

**Note**: Due to [an upstream bug](https://github.com/ziglang/zig/issues/20476), you will probably
receive a warning (or multiple warnings if building for multiple targets) like this:

```
error: warning(link): unexpected LLD stderr:
ld.lld: warning: <path-to-project>/.zig-cache/o/4227869d730f094811a7cdaaab535797/libraylib.a: archive member '<path-to-ndk>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/35/libGLESv2.so' is neither ET_REL nor LLVM bitcode
```

You can ignore this error for now, or see [this PR](https://codeberg.org/ziglang/zig/pulls/31383)
for the changes you can make locally to your std lib to fix the error.

### Build and run natively on your operating system or install/run on Android device

```sh
zig build run           # Native
zig build run -Dandroid # Android - Also installs & runs the app
```

### Build, install to test one target against a local emulator and run

```sh
zig build -Dtarget=x86_64-linux-android
adb install ./zig-out/bin/loki-android.apk
adb shell am start -S -W -n com.zig.loki/android.app.NativeActivity
```

### Build and install for all supported Android targets

```sh
zig build -Dandroid
adb install ./zig-out/bin/loki-android.apk
```

### Uninstall your application

If installing your application fails with something like:

```
adb: failed to install ./zig-out/bin/loki-android.apk: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.zig.loki signatures do not match newer version; ignoring!]
```

```sh
adb uninstall "com.zig.loki"
```

### View logs of application

Powershell (app doesn't need to be running)

```sh
adb logcat | Select-String com.zig.loki:
```

Bash (app doesn't need running to be running)

```sh
adb logcat com.zig.loki:D *:S
```

Bash (app must be running, logs everything by the process including modules)

```sh
adb logcat --pid=`adb shell pidof -s com.zig.loki`
```

## Java & Android SDK Setup

- Install the JAVA SDK from <https://www.oracle.com/java/technologies/downloads/>
  - I used the `.tar.gz` and unpacked it to `~/.local/apps/jdk-24.0.2`
- Install the android [cmdline-tools](https://developer.android.com/studio#command-line-tools-only)
  (use the non-Android Studio tarball option) to `~/.local/apps/android-sdk/cmdline-tools/latest/`

```bash
export JDK_HOME=${HOME}/.local/apps/jdk-25.0.2
export ANDROID_HOME=${HOME}/.local/apps/android-sdk/
# IMPORTANT: This Java version must be found first within your PATH!
export PATH=${JDK_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${PATH}
sdkmanager --install "build-tools;35.0.1"
sdkmanager --install "ndk;29.0.13113456"
sdkmanager --install "platforms;android-35"
sdkmanager --install "platform-tools"
export PATH=${ANDROID_HOME}/platform-tools:${PATH}
sudo usermod -aG plugdev $USER
```
