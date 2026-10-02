#!/data/data/com.termux/files/usr/bin/bash
# Build do Mesa 26.2.3 com Zink acelerado por GPU (Xclipse 940) no Termux.
# Versão de diagnóstico: Zink mínimo, sem sw_winsys/flush_frontbuffer experimental.

set -euo pipefail

MESA_TAG="mesa-26.2.3"
SRC="$PWD/mesa-src"
PREFIX_OUT="$PWD/mesa-zink"
TP="$PWD/termux-packages"
JOBS="${JOBS:-3}"

step() {
    printf '\n=== %s\n' "$*"
}

step "1/7 Dependencias"

pkg update -y >/dev/null 2>&1 || true

pkg install -y \
    git \
    python \
    python-pip \
    ninja \
    pkg-config \
    bison \
    flex \
    glslang \
    libdrm \
    libx11 \
    libxext \
    libxfixes \
    libxshmfence \
    libxxf86vm \
    libxrandr \
    xorgproto \
    libglvnd \
    libandroid-shmem \
    mesa-dev \
    mesa \
    imagemagick \
    clang \
    patch \
    >/dev/null

pip install --break-system-packages \
    meson \
    mako \
    pyyaml \
    packaging \
    >/dev/null

git config --global core.pager cat


step "2/7 Fontes (Mesa + patches do Termux)"

if [ ! -d "$TP/.git" ]; then
    echo "Clonando termux-packages..."
    git clone --depth 1 \
        https://github.com/termux/termux-packages.git \
        "$TP"
fi

if [ ! -d "$SRC/.git" ]; then
    echo "Clonando Mesa $MESA_TAG..."
    git clone --depth 1 \
        --branch "$MESA_TAG" \
        https://gitlab.freedesktop.org/mesa/mesa.git \
        "$SRC"
fi

cd "$SRC"

echo "Restaurando Mesa para $MESA_TAG..."

git fetch --depth 1 origin "$MESA_TAG" >/dev/null 2>&1 || true

git reset --hard -q "$MESA_TAG" 2>/dev/null || \
git reset --hard -q HEAD

git clean -fdq -e build-zink


step "3/7 Patches do Termux"

P="$TP/packages/mesa"

for f in 0000 0002 0003 0004 0006 0008 0011 0015 0017; do
    p=$(ls "$P"/${f}-*)

    echo "  aplicando $(basename "$p")"

    sed "s|@TERMUX_PREFIX@|$PREFIX|g" "$p" |
        patch -p1 --silent
done

find . \
    -name '*.orig' \
    -not -path './build-zink/*' \
    -delete


step "4/7 Ajustes mínimos do Zink"

python3 <<'PY'
from pathlib import Path


def edit(path, old, new):
    path = Path(path)
    s = path.read_text()

    count = s.count(old)

    if count != 1:
        raise SystemExit(
            f"{path}: trecho esperado encontrado {count} vezes; "
            "nenhuma alteração feita."
        )

    path.write_text(s.replace(old, new))


Z = Path("src/gallium/drivers/zink")


# ----------------------------------------------------------------------
# (A)
# VK_KHR_maintenance5 deixa de ser obrigatória.
#
# O driver Samsung Xclipse 940 utilizado neste ambiente anuncia Vulkan
# 1.3, portanto não devemos exigir essa extensão para criar o device.
# ----------------------------------------------------------------------

edit(
    Z / "zink_device_info.py",

    '''    Extension("VK_KHR_maintenance5",
              alias="maint5",
              features=True, properties=True,
              required=True),''',

    '''    Extension("VK_KHR_maintenance5",
              alias="maint5",
              features=True, properties=True),'''
)


# ----------------------------------------------------------------------
# (B)
# Seleção de physical device.
#
# Se o render node informado pelo X/DRI3 não corresponder ao DRM
# reportado pelo Vulkan, usamos o primeiro physical device disponível.
#
# Isso é apenas fallback de seleção.
# Não alteramos ainda o caminho de apresentação.
# ----------------------------------------------------------------------

edit(
    Z / "zink_screen.c",

    """         return i;
   }

   return -1;
}

static int
zink_get_cpu_device_type""",

    """         return i;
   }

   return pdev_count ? 0 : -1;
}

static int
zink_get_cpu_device_type"""
)


print("Ajustes mínimos do Zink aplicados.")
PY


step "5/7 Configurar (meson)"

rm -rf build-zink

meson setup build-zink \
    --prefix="$PREFIX_OUT" \
    -Dgallium-drivers=zink \
    -Dvulkan-drivers= \
    -Dllvm=disabled \
    -Dgallium-rusticl=false \
    -Dopengl=true \
    -Degl=enabled \
    -Dglx=dri \
    -Dgbm=disabled \
    -Dplatforms=x11 \
    -Dglvnd=enabled \
    -Dxmlconfig=disabled \
    -Dgles1=disabled \
    -Dgles2=enabled \
    -Dbuildtype=release \
    -Dstrip=true \
    -Dc_link_args="-Wl,--undefined-version -landroid-shmem" \
    -Dcpp_link_args="-Wl,--undefined-version -landroid-shmem" \
    >/dev/null


step "6/7 Compilar"

echo "Compilando Mesa 26.2.3 com -j$JOBS..."

termux-wake-lock 2>/dev/null || true

ninja -C build-zink -j"$JOBS"

echo "Instalando em:"
echo "  $PREFIX_OUT"

ninja -C build-zink install >/dev/null

termux-wake-unlock 2>/dev/null || true


step "7/7 Wrapper"

mkdir -p "$HOME/.local/bin"

cat > "$HOME/.local/bin/zink" <<WRAP
#!/data/data/com.termux/files/usr/bin/bash

export GALLIUM_DRIVER=zink
export LIBGL_DRIVERS_PATH="$PREFIX_OUT/lib/dri"
export LD_LIBRARY_PATH="$PREFIX_OUT/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

exec "\$@"
WRAP

chmod +x "$HOME/.local/bin/zink"


echo
echo "============================================================"
echo "Mesa 26.2.3 + Zink instalado."
echo "============================================================"
echo
echo "Prefixo:"
echo "  $PREFIX_OUT"
echo
echo "Wrapper:"
echo "  $HOME/.local/bin/zink"
echo
echo "Inicie o Termux:X11:"
echo
echo "  termux-x11 :0 &"
echo
echo "Teste:"
echo
echo "  DISPLAY=:0 ~/.local/bin/zink glxinfo -B"
echo
echo "Depois:"
echo
echo "  DISPLAY=:0 ~/.local/bin/zink glxgears"
echo
