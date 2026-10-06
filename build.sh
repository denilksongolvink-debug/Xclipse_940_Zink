#!/data/data/com.termux/files/usr/bin/bash
# Zink (Mesa 26.2.3) na GPU Xclipse 940 / Termux:X11
set -euo pipefail
trap 'echo ">>> FALHOU na linha $LINENO"' ERR

MESA_TAG="${MESA_TAG:-mesa-26.2.3}"
BASE="${BASE:-$PWD}"
SRC="$BASE/mesa-26.2.3"          # pasta nova: nao mexe no seu mesa-src antigo
OUT="$BASE/zink-install"
VKLIB="$BASE/vklib"
TP="$BASE/termux-packages"
JOBS="${JOBS:-3}"
step() { printf '\n=== %s\n' "$*"; }
mkdir -p "$BASE" "$HOME/.bin"

step "1/8 Dependencias"
pkg update -y >/dev/null 2>&1 || true
pkg install -y x11-repo >/dev/null 2>&1 || true
pkg install -y git python python-pip ninja pkg-config bison flex glslang \
  libdrm libx11 libxext libxfixes libxshmfence libxxf86vm libxrandr xorgproto \
  libglvnd libandroid-shmem mesa-demos vulkan-tools imagemagick clang patch >/dev/null
pkg install -y libglvnd-dev >/dev/null 2>&1 || true
pip install --break-system-packages meson mako pyyaml packaging >/dev/null
git config --global core.pager cat

step "2/8 Fontes"
[ -d "$TP" ] || git clone --depth 1 https://github.com/termux/termux-packages.git "$TP"
TV=$(grep -m1 '^TERMUX_PKG_VERSION=' "$TP/packages/mesa/build.sh" | cut -d'"' -f2 || true)
[ "mesa-$TV" = "$MESA_TAG" ] || echo "AVISO: patches do Termux sao da versao '$TV', voce pediu '$MESA_TAG'"
[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$MESA_TAG" https://gitlab.freedesktop.org/mesa/mesa.git "$SRC"
cd "$SRC"
git reset --hard -q "$MESA_TAG"
git clean -fdq

step "3/8 Patches do Termux"
for f in 0000 0002 0003 0004 0006 0008 0011 0015 0017; do
  p=$(ls "$TP"/packages/mesa/${f}-*)
  echo "  $(basename "$p")"
  sed "s|@TERMUX_PREFIX@|$PREFIX|g" "$p" | patch -p1 --silent
done
find . -name '*.orig' -delete

step "4/8 Consertos do Zink"
python3 - <<'PYEOF'
def edit(path, old, new):
    s = open(path).read()
    assert s.count(old) == 1, f"{path}: trecho achado {s.count(old)}x: {old[:60]!r}"
    open(path, "w").write(s.replace(old, new))
Z = "src/gallium/drivers/zink/"
# (a) maintenance5 deixa de ser obrigatoria (Samsung anuncia so Vulkan 1.3)
edit(Z+"zink_device_info.py",
'''    Extension("VK_KHR_maintenance5",
              alias="maint5",
              features=True, properties=True,
              required=True),''',
'''    Extension("VK_KHR_maintenance5",
              alias="maint5",
              features=True, properties=True),''')
# (b) choose_pdev: se nenhum device casar com o render node, usa o primeiro
edit(Z+"zink_screen.c",
"         return i;\n   }\n\n   return -1;\n}\n\nstatic int\nzink_get_cpu_device_type",
"         return i;\n   }\n\n   return pdev_count ? 0 : -1;\n}\n\nstatic int\nzink_get_cpu_device_type")
# (c) campos de apresentacao por software, DEPOIS de 'base' (tem que ser o 1o membro)
edit(Z+"zink_types.h",
"struct zink_screen {\n   struct pipe_screen base;\n",
"struct sw_winsys;\nstruct sw_displaytarget;\nstruct zink_screen {\n   struct pipe_screen base;\n"
"   struct sw_winsys *sw_winsys;\n   struct sw_displaytarget *sw_dt;\n   unsigned sw_dt_w, sw_dt_h, sw_dt_stride;\n")
# (d) guardar o winsys recebido
edit(Z+"zink_screen.c",
"   if (ret) {\n      ret->drm_fd = -1;\n   }",
"   if (ret) {\n      ret->drm_fd = -1;\n      ret->sw_winsys = winsys;\n   }")
# (e) includes (sw_winsys.h DEPOIS de zink_screen.h)
edit(Z+"zink_screen.c", '#include "zink_screen.h"',
'#include "zink_screen.h"\n#include "util/u_inlines.h"\n#include "frontend/sw_winsys.h"')
# (f) flush_frontbuffer sem kopper -> entrega o frame ao X11 via sw_winsys
edit(Z+"zink_screen.c",
"""   /* if the surface is no longer a swapchain, this is a no-op */
   if (!zink_is_swapchain(res))
      return;
""",
"""   if (!zink_is_swapchain(res)) {
      struct sw_winsys *ws = screen->sw_winsys;
      if (!ws || !winsys_drawable_handle)
         return;
      pctx->flush(pctx, NULL, 0);
      unsigned w = pres->width0, h = pres->height0;
      struct pipe_transfer *xfer = NULL;
      uint8_t *src = pipe_texture_map(pctx, pres, level, 0, PIPE_MAP_READ, 0, 0, w, h, &xfer);
      if (!src) { mesa_loge("ZINK: present sem kopper: map falhou"); return; }
      if (!screen->sw_dt || screen->sw_dt_w != w || screen->sw_dt_h != h) {
         if (screen->sw_dt) ws->displaytarget_destroy(ws, screen->sw_dt);
         unsigned stride = 0;
         screen->sw_dt = ws->displaytarget_create(ws, 0, pres->format, w, h, 64, NULL, &stride);
         screen->sw_dt_w = w; screen->sw_dt_h = h; screen->sw_dt_stride = stride;
      }
      if (screen->sw_dt) {
         uint8_t *dst = ws->displaytarget_map(ws, screen->sw_dt, PIPE_MAP_WRITE);
         if (dst) {
            unsigned n = MIN2(screen->sw_dt_stride, xfer->stride);
            for (unsigned y = 0; y < h; y++)
               memcpy(dst + (size_t)y * screen->sw_dt_stride, src + (size_t)y * xfer->stride, n);
            ws->displaytarget_unmap(ws, screen->sw_dt);
            ws->displaytarget_display(ws, screen->sw_dt, winsys_drawable_handle, nboxes, sub_box);
         } else { mesa_loge("ZINK: present sem kopper: dt map falhou"); }
      } else { mesa_loge("ZINK: present sem kopper: dt create falhou"); }
      pipe_texture_unmap(pctx, xfer);
      return;
   }
""")
print("consertos do Zink aplicados")
PYEOF

step "5/8 Clamp opcional de swap_interval (so liga com MESA_SWAP_CLAMP=1)"
python3 - <<'PYEOF' || echo "AVISO: clamp nao aplicado (ancora mudou); o resto segue normal"
p = "src/gallium/frontends/dri/loader_dri3_helper.c"
s = open(p).read()
a = "   draw->vtable->flush_drawable(draw, flush_flags);"
assert s.count(a) == 1, f"ancora achada {s.count(a)}x"
ins = ("   /* MESA_SWAP_CLAMP: Present ASYNC sem contrapeso do servidor faz a imagem piscar */\n"
       "   if (draw->swap_interval == 0 && getenv(\"MESA_SWAP_CLAMP\"))\n"
       "      draw->swap_interval = 1;\n")
open(p, "w").write(s.replace(a, ins + a))
print("clamp aplicado")
PYEOF

step "6/8 Configurar (meson)"
GLVND_INC=""
if [ ! -e "$PREFIX/include/glvnd/libglxabi.h" ]; then
  echo "header glvnd/libglxabi.h ausente: baixando do libglvnd"
  rm -rf "$BASE/glvnd-src" "$BASE/glvnd-inc"
  git clone --depth 1 https://github.com/NVIDIA/libglvnd.git "$BASE/glvnd-src"
  mkdir -p "$BASE/glvnd-inc"
  cp -r "$BASE/glvnd-src/include/glvnd" "$BASE/glvnd-inc/"
  GLVND_INC="-I$BASE/glvnd-inc"
fi
rm -rf build-zink
meson setup build-zink --prefix="$OUT" \
  -Dgallium-drivers=zink -Dvulkan-drivers= -Dllvm=disabled -Dgallium-rusticl=false \
  -Dopengl=true -Degl=enabled -Dglx=dri -Dgbm=disabled -Dplatforms=x11 \
  -Dglvnd=enabled -Dxmlconfig=disabled -Dgles1=disabled -Dgles2=enabled \
  -Dbuildtype=release -Dstrip=false \
  -Dc_args="$GLVND_INC" -Dcpp_args="$GLVND_INC" \
  -Dc_link_args="-Wl,--undefined-version -landroid-shmem" \
  -Dcpp_link_args="-Wl,--undefined-version -landroid-shmem" >/dev/null

step "7/8 Compilar e instalar (20-40 min, -j$JOBS)"
termux-wake-lock 2>/dev/null || true
ninja -C build-zink -j"$JOBS"
ninja -C build-zink install >/dev/null
termux-wake-unlock 2>/dev/null || true
# o glvnd abre libGLX_mesa.so.0 / libEGL_mesa.so.0; o install do meson nao cria esses links
ln -sf libGLX_mesa.so "$OUT/lib/libGLX_mesa.so.0"
ln -sf libEGL_mesa.so "$OUT/lib/libEGL_mesa.so.0"

step "8/8 Loader Vulkan do Android + wrappers"
mkdir -p "$VKLIB"
ln -sf /system/lib64/libvulkan.so "$VKLIB/libvulkan.so.1"
ln -sf /system/lib64/libvulkan.so "$VKLIB/libvulkan.so"

mk_wrapper() {  # $1=nome  $2=linha extra de export
cat > "$HOME/.bin/$1" <<WRAP
#!/data/data/com.termux/files/usr/bin/bash
export DISPLAY=:0 GALLIUM_DRIVER=zink LIBGL_KOPPER_DISABLE=true
$2
unset VK_ICD_FILENAMES VK_DRIVER_FILES VK_ADD_DRIVER_FILES
export LIBGL_DRIVERS_PATH="$OUT/lib/dri"
export __EGL_VENDOR_LIBRARY_FILENAMES="$OUT/share/glvnd/egl_vendor.d/50_mesa.json"
export LD_LIBRARY_PATH="$VKLIB:$OUT/lib"
exec "\$@"
WRAP
chmod +x "$HOME/.bin/$1"
}
mk_wrapper zink ""                                                         # estavel: sw_winsys
mk_wrapper zink-dri3 "export MESA_LOADER_DRIVER_OVERRIDE=zink MESA_SWAP_CLAMP=1"  # exige Termux:X11 com DRI3

echo; echo "=== TESTE ==="
pgrep -f termux-x11 >/dev/null || { termux-x11 :0 >/dev/null 2>&1 & sleep 3; }
echo "patches no binario: $(grep -ac 'present sem kopper' "$OUT"/lib/libgallium-*.so) (esperado >= 1)"
echo "--- Vulkan:"; ~/.bin/zink vulkaninfo --summary 2>&1 | grep -E "deviceName|ERROR" | head -3 || true
echo "--- GLX:";    ~/.bin/zink glxinfo -B 2>&1 | grep -E "renderer string|Accelerated|failed|ZINK" | head -5 || true
~/.bin/zink glxgears >/dev/null 2>&1 & p=$!; sleep 3
echo "--- libs carregadas (devem estar em $BASE):"
grep -oE '[^ ]*(libgallium|libGLX_mesa)[^ ]*' /proc/$p/maps 2>/dev/null | sort -u || true
kill $p 2>/dev/null || true
echo; echo "Uso:  ~/.bin/zink glxgears     (estavel, ~200 FPS)"
echo "      ~/.bin/zink-dri3 glmark2 (DRI3/dma-buf; so com seu Termux:X11 modificado)"

tee $BASE/install-xclipse-zink.log
