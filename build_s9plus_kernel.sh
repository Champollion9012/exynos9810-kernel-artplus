#!/usr/bin/env bash
set -euo pipefail

# Directory Setup
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KERNEL_DIR"

# Basic Configuration
ARCH=arm64
PROFILE="${PROFILE:-exynos9810_star2_kor}"
JOBS="${JOBS:-$(nproc)}"
# Use existing compiler path or default
CR_CLANG="${CR_CLANG:-/home/j/compiler/clang-20.0.0-r547379}"

# Packaging configuration (Referencing Apollo.sh structure)
CR_AIK="$KERNEL_DIR/Apollo/A.I.K"
CR_RAMDISK="$KERNEL_DIR/Apollo/Ramdisk"
CR_OUT="$KERNEL_DIR/out_packages"
mkdir -p "$CR_OUT"

# Safety Check for Compiler
if [[ ! -x "$CR_CLANG/bin/clang" ]]; then
  echo "[!] clang not found at: $CR_CLANG/bin/clang"
  exit 1
fi

echo "[*] Kernel dir : $KERNEL_DIR"
echo "[*] Profile    : $PROFILE"
echo "[*] Output     : $CR_OUT"
echo "[*] Compiler   : $CR_CLANG"

# Export Environment (Clang + LLVM)
export CONFIG_THINLTO=y
export CONFIG_UNIFIEDLTO=y
export CONFIG_LLVM_MLGO_REGISTER=y
export CONFIG_LLVM_POLLY=y
export CONFIG_LLVM_DFA_JUMP_THREAD=y

export PATH="$CR_CLANG/bin:$CR_CLANG/lib:${PATH}"
export CC="$CR_CLANG/bin/clang"
export REAL_CC="$CR_CLANG/bin/clang"
export LD="$CR_CLANG/bin/ld.lld"
export AR="$CR_CLANG/bin/llvm-ar"
export NM="$CR_CLANG/bin/llvm-nm"
export OBJCOPY="$CR_CLANG/bin/llvm-objcopy"
export OBJDUMP="$CR_CLANG/bin/llvm-objdump"
export READELF="$CR_CLANG/bin/llvm-readelf"
export STRIP="$CR_CLANG/bin/llvm-strip"
export LLVM=1
export KALLSYMS_EXTRA_PASS=1
export ARCH=arm64
export SUBARCH=arm64
export ANDROID_MAJOR_VERSION=q
# Define make command array
make_cmd=(make ARCH="$ARCH" CC=clang)

# Helper Functions
kconfig_has() {
  local sym="$1"
  grep -REqs --include='Kconfig*' "^(menuconfig|config)[[:space:]]+$sym$" .
}

cfg_enable() {
  local sym="$1"
  if kconfig_has "$sym"; then
    ./scripts/config --file .config -e "$sym"
  fi
}

cfg_disable() {
  local sym="$1"
  if kconfig_has "$sym"; then
    ./scripts/config --file .config -d "$sym"
  fi
}

# Generate Config based on Profile (No QEMU specifics)
generate_config() {
  local tmpcfg="arch/arm64/configs/tmp_defconfig"
  echo "[*] Generating $tmpcfg for $PROFILE"

  # Base configs targeting S9+ Korean (matching previous logic)
  cat arch/arm64/configs/exynos9810_defconfig > "$tmpcfg"
  cat arch/arm64/configs/star2lte_defconfig >> "$tmpcfg"
  cat arch/arm64/configs/kor_defconfig >> "$tmpcfg"
  
  if [[ -f arch/arm64/configs/apollo_defconfig ]]; then
    cat arch/arm64/configs/apollo_defconfig >> "$tmpcfg"
  fi
  
  # Target Specifics
  echo "CONFIG_MACH_EXYNOS9810_STAR2LTE_KOR=y" >> "$tmpcfg"
  echo "CONFIG_ALWAYS_PERMISSIVE=y" >> "$tmpcfg"
  echo "CONFIG_KSU=y" >> "$tmpcfg"

  # Apply defconfig
  "${make_cmd[@]}" tmp_defconfig
}

generate_config

echo "[*] Configuring BPF & Tracing Features"

# --- BPF Dependency Chain ---
# 1. MODULES (Root dependency)
cfg_enable MODULES

# 2. BPF Core
cfg_enable BPF
cfg_enable BPF_SYSCALL
cfg_enable BPF_JIT

# 3. Tracing (Required for BPF_EVENTS)
cfg_enable PERF_EVENTS
#cfg_enable FTRACE
cfg_enable KPROBES
cfg_enable KPROBE_EVENT
#cfg_enable UPROBES
#cfg_enable UPROBE_EVENT

# 4. Debugging Headers
cfg_enable IKHEADERS
cfg_disable DEBUG_INFO_BTF

# Essential Hardware Configs
cfg_enable SEC_DEBUG
cfg_enable EXYNOS_SNAPSHOT
cfg_enable CMA
cfg_enable THERMAL
cfg_enable PM_DEVFREQ
cfg_enable PM_OPP
cfg_enable PWRCAL

echo "[*] Resolving dependencies (olddefconfig)"
"${make_cmd[@]}" olddefconfig

echo "[*] Building Kernel Image & DTB"
# Build Image and dtbs (compiles device tree blobs)
"${make_cmd[@]}" -j"$JOBS" Image dtbs

# Verify Build Artifacts
KERNEL_IMAGE="arch/arm64/boot/Image"
DTB_IMAGE="arch/arm64/boot/dtb.img"

if [[ ! -f "$KERNEL_IMAGE" ]]; then
  echo "[!] Failed: Kernel Image not found at $KERNEL_IMAGE"
  exit 1
fi

if [[ ! -f "$DTB_IMAGE" ]]; then
  echo "[!] Failed: DTB Image not found at $DTB_IMAGE"
  # Attempt to create dtb.img if direct build failed but dtb files exist?
  # Assuming make Image/dtbs handles it for this vendor tree.
  echo "[!] (Note: Check if 'dtb.img' requires manual dtbtool usage)"
  exit 1
fi

echo "[*] Build Success! Packaging..."

# Packaging Logic (Based on PACK_BOOT_IMG from apollo.sh)
package_boot_img() {
  if [[ ! -d "$CR_AIK" ]] || [[ ! -d "$CR_RAMDISK" ]]; then
    echo "[!] Packaging tools missing (Apollo/A.I.K or Apollo/Ramdisk)"
    return
  fi

  echo "[*] Preparing AIK workspace..."
  # Clean up existing image in AIK if any
  if [[ -f "$CR_AIK/image-new.img" ]]; then
      rm -f "$CR_AIK/image-new.img"
  fi

  # Copy Ramdisk content (ramdisk/ and split_img/ directories)
  cp -rf "$CR_RAMDISK/"* "$CR_AIK/"

  # Ensure split_img directory exists
  mkdir -p "$CR_AIK/split_img"

  # Move Kernel and DTB to AIK split_img folder
  echo "[*] Copying Kernel and DTB to split_img..."
  cp -f "$KERNEL_IMAGE" "$CR_AIK/split_img/boot.img-zImage"
  cp -f "$DTB_IMAGE" "$CR_AIK/split_img/boot.img-dtb"

  # Pack the image
  echo "[*] Running repackimg.sh ..."
  pushd "$CR_AIK" > /dev/null
  if [[ -x "./repackimg.sh" ]]; then
      ./repackimg.sh
  else
      bash ./repackimg.sh
  fi
  popd > /dev/null

  # Verify and Setup Output
  if [[ -f "$CR_AIK/image-new.img" ]]; then
      # Add SEANDROIDENFORCE footer for Samsung bootloader check
      echo -n "SEANDROIDENFORCE" >> "$CR_AIK/image-new.img"
      
      # Copy to output
      cp -f "$CR_AIK/image-new.img" "$CR_OUT/boot.img"
      cp -f ".config" "$CR_OUT/kernel.config"
      
      echo "[SUCCESS] boot.img created at: $CR_OUT/boot.img"
  else
      echo "[!] Failed to create boot.img"
      exit 1
  fi
  
  # Optional: Clean up AIK temp files
  # "$CR_AIK/cleanup.sh" 
}

package_boot_img
