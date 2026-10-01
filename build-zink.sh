#!/data/data/com.termux/files/usr/bin/bash
# Build do Mesa 26.2.3 com Zink acelerado por GPU (Xclipse 940) no Termux.
set -euo pipefail

MESA_TAG="mesa-26.2.3"
SRC="$PWD/mesa-src"
PREFIX_OUT="$PWD/mesa-zink"
TP="$PWD/termux-packages"
JOBS="${JOBS:-3}"

step() { printf '\n=== %s\n' "$*"; }

step "1/7 Dependencias"
pkg update -y >/dev/null 2>&1 || true
pkg install -y git python python-pip ninja pkg-config bison flex glslang \
  libdrm libx11 libxext libxfixes libxshmfence libxxf86vm libxrandr xorgproto \
  libglvnd libandroid-shmem mesa-dev mesa imagemagick clang patch >/dev/null
pip install --break-system-packages meson mako pyyaml packaging >/dev/null
git config --global core.pager cat

step "2/7 Fontes (Mesa + patches do Termux)"
[ -d "$TP" ] || git clone --depth 1 https://github.com/termux/termux-packages.git "$TP"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$MESA_TAG" https://gitlab.freedesktop.org/mesa/mesa.git "$SRC"
fi
cd "$SRC"
git reset --hard -q "$MESA_TAG" 2>/dev/null || git reset --hard -q HEAD
git clean -fdq -e build-zink

step "3/7 Patches do Termux"
P="$TP/packages/mesa"
for f in 0000 0002 0003 0004 0006 0008 0011 0015 0017; do
  p=$(ls "$P"/${f}-*)
  echo "  aplicando $(basename "$p")"
  sed "s|@TERMUX_PREFIX@|$PREFIX|g" "$p" | patch -p1 --silent
done
find . -name '*.orig' -not -path './build-zink/*' -delete

step "4/7 Nossos consertos no Zink"
python3 - <<'EOF'
def edit(path, old, new):
    s = open(path).read()
    assert s.count(old) == 1, f"{path}: trecho encontrado {s.count(old)}x: {old[:60]!r}"
    open(path, "w").write(s.replace(old, new))

Z = "src/gallium/drivers/zink/"

# (a) VK_KHR_maintenance5 deixa de ser obrigatoria (a Samsung so anuncia Vulkan 1.3)
edit(Z + "zink_device_info.py",
'''    Extension("VK_KHR_maintenance5",
              alias="maint5",
              features=True, properties=True,
              required=True),''',
'''    Extension("VK_KHR_maintenance5",
              alias="maint5",
              features=True, properties=True),''')

# (b) escolha de device: se nenhum casar com o render node, usa o primeiro
edit(Z + "zink_screen.c",
"         return i;\n   }\n\n   return -1;\n}\n\nstatic int\nzink_get_cpu_device_type",
"         return i;\n   }\n\n   return pdev_count ? 0 : -1;\n}\n\nstatic int\nzink_get_cpu_device_type")

# (c) campos p/ apresentacao por software (DEPOIS de 'base', que precisa ser o 1o membro)
edit(Z + "zink_types.h",
"struct zink_screen {\n   struct pipe_screen base;\n",
"struct sw_winsys;\nstruct sw_displaytarget;\nstruct zink_screen {\n   struct pipe_screen base;\n"
"   struct sw_winsys *sw_winsys;\n   struct sw_displaytarget *sw_dt;\n   unsigned sw_dt_w, sw_dt_h, sw_dt_stride;\n")

# (d) guardar o winsys recebido
edit(Z + "zink_screen.c",
"   if (ret) {\n      ret->drm_fd = -1;\n   }",
"   if (ret) {\n      ret->drm_fd = -1;\n      ret->sw_winsys = winsys;\n   }")

# (e) includes: sw_winsys.h precisa vir DEPOIS de zink_screen.h (define bool e tipos pipe_*)
edit(Z + "zink_screen.c",
'#include "zink_screen.h"',
'#include "zink_screen.h"\n#include "util/u_inlines.h"\n#include "frontend/sw_winsys.h"')

# (f) flush_frontbuffer sem kopper: le o resultado e entrega ao X11 via sw_winsys
edit(Z + "zink_screen.c",
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
      if (!src) {
         mesa_loge("ZINK: present sem kopper: map falhou");
         return;
      }
      if (!screen->sw_dt || screen->sw_dt_w != w || screen->sw_dt_h != h) {
         if (screen->sw_dt)
            ws->displaytarget_destroy(ws, screen->sw_dt);
         unsigned stride = 0;
         screen->sw_dt = ws->displaytarget_create(ws, 0, pres->format, w, h, 64, NULL, &stride);
         screen->sw_dt_w = w;
         screen->sw_dt_h = h;
         screen->sw_dt_stride = stride;
      }
      if (screen->sw_dt) {
         uint8_t *dst = ws->displaytarget_map(ws, screen->sw_dt, PIPE_MAP_WRITE);
         if (dst) {
            unsigned n = MIN2(screen->sw_dt_stride, xfer->stride);
            for (unsigned y = 0; y < h; y++)
               memcpy(dst + (size_t)y * screen->sw_dt_stride, src + (size_t)y * xfer->stride, n);
            ws->displaytarget_unmap(ws, screen->sw_dt);
            ws->displaytarget_display(ws, screen->sw_dt, winsys_drawable_handle, nboxes, sub_box);
         } else {
            mesa_loge("ZINK: present sem kopper: dt map falhou");
         }
      } else {
         mesa_loge("ZINK: present sem kopper: dt create falhou");
      }
      pipe_texture_unmap(pctx, xfer);
      return;
   }
""")
print("consertos aplicados")
EOF

step "5/7 Configurar (meson)"
rm -rf build-zink
meson setup build-zink \
  --prefix="$PREFIX_OUT" \
  -Dgallium-drivers=zink -Dvulkan-drivers= -Dllvm=disabled -Dgallium-rusticl=false \
  -Dopengl=true -Degl=enabled -Dglx=dri -Dgbm=disabled -Dplatforms=x11 \
  -Dglvnd=enabled -Dxmlconfig=disabled -Dgles1=disabled -Dgles2=enabled \
  -Dbuildtype=release -Dstrip=true \
  -Dc_link_args="-Wl,--undefined-version -landroid-shmem" \
  -Dcpp_link_args="-Wl,--undefined-version -landroid-shmem" >/dev/null

step "6/7 Compilar (demora; -j$JOBS)"
termux-wake-lock 2>/dev/null || true
ninja -C build-zink -j"$JOBS"
ninja -C build-zink install >/dev/null
termux-wake-unlock 2>/dev/null || true

step "7/7 Wrapper e teste"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/zink" <<WRAP
#!/data/data/com.termux/files/usr/bin/bash
export GALLIUM_DRIVER=zink 
export LIBGL_KOPPER_DISABLE=true
export LIBGL_DRIVERS_PATH="$PREFIX_OUT/lib/dri"
export LD_LIBRARY_PATH="$PREFIX_OUT/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
WRAP
chmod +x "$HOME/.local/bin/zink"

echo
echo "Pronto. Suba o Termux:X11 (termux-x11 :0 &) e teste:"
echo "  DISPLAY=:0 ~/.local/bin/zink glxinfo -B | grep -i renderer"
echo "  DISPLAY=:0 ~/.local/bin/zink glxgears"
