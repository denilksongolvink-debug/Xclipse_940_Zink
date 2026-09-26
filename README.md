# Zink com aceleração de GPU no Termux — Galaxy S24 / Exynos 2400 / Xclipse 940

**Status: v0.9 — funcional, experimental, corretude parcialmente validada.**

Mesa 26.2.3 com Zink (OpenGL sobre Vulkan) rodando na GPU Xclipse 940 via
driver Vulkan proprietário da Samsung, apresentando no Termux:X11 por GLX
(kopper desligado, apresentação via caminho de software).

## TL;DR

- Zink funciona no Xclipse 940 com patches específicos (nenhum encontrado
  publicamente documentado da mesma forma — ver seção "Confirmação externa").
- glmark2 score 166 (GPU) vs 82 (llvmpipe/CPU) — mas **corretude visual em
  cenas complexas não foi confirmada** (ver "Riscos conhecidos").
- Só GLX funciona. EGL sobre X11 falha. Navegador nunca foi testado.
- Uma tentativa de otimizar sincronização (`zink_fence_wait` →
  `zink_resource_usage_wait`) foi testada e **revertida** — documentada
  como experimento negativo, não como sucesso.

## Hardware e ambiente

- Samsung Galaxy S24, Exynos 2400, GPU Xclipse 940 (RDNA3 customizada AMD)
- Kernel driver da GPU: `sgpu` (render node `/dev/dri/renderD128`;
  `renderD129` é `exynos-drm`, controlador de display, não GPU)
- Vulkan 1.3.279, driver proprietário Samsung
  (`/vendor/lib64/hw/vulkan.samsung.so`), 168 extensões, carregado pelo
  loader Vulkan do Android (`libvulkan.so` do Termux é symlink pra
  `/system/lib64/libvulkan.so` — não existe ICD JSON, `VK_ICD_FILENAMES`
  não tem efeito)
- Termux + Termux:X11, Mesa 26.2.3 (tag `mesa-26.2.3`)

## Caminho de referência (sempre funcionou, sem nossos patches)
virgl → protocolo de virtualização → `angle-android` → Vulkan Samsung.
Imagem correta, ~160-200 FPS no glxgears. Usar como controle de corretude
ao comparar com o Zink.

## Os 6 problemas resolvidos (Zink direto, sem virgl)

| # | Sintoma | Causa confirmada | Solução |
|---|---|---|---|
| 1 | `ZINK: failed to choose pdev` | Mesa abre 2 render nodes (226:128 GPU, 226:129 display); Zink só aceita se `renderMajor:renderMinor` casar exatamente | `zink_get_display_device`: fallback pro device 0 se nada casar |
| 2 | `VK_KHR_maintenance5 required!` | Mesa 26 marca como obrigatória; Samsung é Vulkan 1.3, não anuncia essa extensão | `zink_device_info.py`: removido `required=True` (único uso real no Zink é leitura de `polygonModePointSize`, que cai em fallback seguro se ausente) |
| 3 | Link: símbolo `_mesa_glapi_tls_Dispatch` indefinido | TLS emulado (API Android ≤28) renomeia pra `__emutls_v.*` | Patch `0011` do Termux + `-Wl,--undefined-version` |
| 4 | Link: `libandroid_shmget/shmat/...` indefinido | Bionic não tem SysV shm | `-landroid-shmem` |
| 5 | Segfault em `zink_kopper_displaytarget_create` | Kopper chama `vkCreateXcbSurfaceKHR`; driver Samsung só expõe `VK_KHR_android_surface` (confirmado via backtrace com símbolos) | Kopper desligado (`LIBGL_KOPPER_DISABLE=true`). **Sem solução real encontrada** — ver issue #25397 |
| 6 | Tela preta com kopper desligado (render correto por baixo) | `zink_flush_frontbuffer` retornava sem apresentar quando o resource não é swapchain. Confirmado via readback em FBO (cores corretas) + screenshot do X11 (`max=0`, frame nunca chegava) | Novo código: `pipe_texture_map` lê o resource, copia pra `sw_displaytarget`, `displaytarget_display` entrega ao X11 (mesmo caminho que llvmpipe usa) |

Detalhe técnico do #6 (`zink_screen.c`, `zink_flush_frontbuffer`): cria/cacheia
um `sw_displaytarget` por tamanho de frame em `screen->sw_dt`; refaz só se
w/h mudar. Recebe `sw_winsys` guardado em `zink_create_screen` (campo novo em
`struct zink_screen`, inserido **depois** de `base` — esse struct exige que
`base` seja o primeiro membro, cast direto assume offset 0).

## Experimento negativo: otimização de sincronização (revertido)

**Tentativa:** em `zink_image_map` (branch de leitura via staging buffer),
trocar `zink_fence_wait(pctx)` (espera todo o contexto, com
`PIPE_FLUSH_HINT_FINISH`) por `zink_resource_usage_wait(ctx, staging_res,
ZINK_RESOURCE_ACCESS_WRITE)` (espera só o resource específico) — um padrão
que já existe no branch vizinho do mesmo arquivo.

**Resultado:** corretude preservada (readback seguiu correto), `glxgears`
isolado melhorou (~220→250-350 FPS), mas `glmark2` completo **caiu** de
166 para 142-155, mesmo com pausas para resfriamento do dispositivo entre
medições. A função é genérica (usada por todo `glReadPixels`/mapeamento de
leitura no driver, não só nossa apresentação), então o ganho local não se
traduziu em ganho geral.

**Lição de processo:** medir performance em celular sob carga sequencial é
não confiável — throttling térmico contamina comparações. Mesmo com 5min de
tela desligada entre medições, resíduo térmico pode persistir.

**Estado atual do código:** revertido para `zink_fence_wait(pctx)` original
nos dois branches (upstream + nossos patches, sem modificação de
sincronização).

## Confirmação e alerta externos (issue termux/termux-packages #25397)

Reportado por terceiro testando Zink em várias GPUs Android via
`mesa-vulkan-icd-wrapper`:

- **Adreno 660**: Zink nem carrega (`failed to load driver: zink`)
- **Adreno 740/750/830**: `VK_ERROR_UNKNOWN` em cenas de `glmark2`, crash;
  WebGL congela o navegador
- **Xclipse 940 (nosso hardware)**: `glmark2`/`glmark2-es2` "rodam com
  sucesso" — mas **"Visual Broken" em OpenGL real (Shotcut, Kdenlive,
  Blender, Supertuxkart)** e **"corrupted graphics" em WebGL no Firefox**

Conclusão do autor: *"At the moment, only Samsung Xclipse GPU can barely
run mesa zink, but even then, it's just enough for glmark2 to barely
function."* Ele propõe abandonar Zink em favor de ANGLE nativo com backend
Vulkan (ver "Próximos passos").

**Isso é uma segunda fonte independente confirmando que Xclipse é a única
GPU Android onde Zink tem alguma chance — e que "rodar o glmark2" não
implica corretude visual em geral.** Nosso teste de corretude (`rt.c`) só
cobre clear + triângulo simples em FBO offscreen. Nunca testamos textura
complexa, múltiplos passes, ou uma aplicação real. **Corrupção visual em
carga complexa é um risco não descartado, não uma hipótese remota.**

## Riscos conhecidos / não testado

- Corrupção visual em cenas complexas (ver confirmação externa acima) —
  **não testado no nosso build**.
- Só GLX. EGL sobre X11 falha (`failed to create dri2 screen`,
  `DRI3 error: Could not get DRI3 device`). Chromium/Firefox via ANGLE/EGL
  **nunca testados** — provavelmente não usam este caminho de qualquer
  forma.
- `displaytarget` cacheado por `zink_screen`, não por janela — múltiplas
  janelas de tamanhos diferentes: comportamento não testado.
- Teto de apresentação ~170-350 FPS (cópia GPU→CPU→X11 por frame), bem
  abaixo do que WSI zero-copy nativo entregaria.
- Cache de pipeline: `vkGetPipelineCacheData failed (VK_INCOMPLETE)`
  observado uma vez; possível que não persista entre execuções.

## Como reconstruir

Script `build-zink.sh` automatiza: dependências, clone da tag
`mesa-26.2.3`, patches do Termux (`0000 0002 0003 0004 0006 0008 0011 0015
0017` de `packages/mesa/`), os 3 consertos do Zink (problemas #1, #2, #6
da tabela acima — aplicar `zink-patches.diff` neste repo), configuração
meson, build e install em `~/mesa-zink`.

Flags meson principais: `-Dgallium-drivers=zink -Dllvm=disabled
-Dgallium-rusticl=false -Dplatforms=x11 -Dglx=dri -Degl=enabled
-Dgbm=disabled -Dglvnd=enabled -Dxmlconfig=disabled -Dgles1=disabled
-Dgles2=enabled -Dbuildtype=release -Dc_link_args="-Wl,--undefined-version
-landroid-shmem" -Dcpp_link_args="-Wl,--undefined-version -landroid-shmem"`

## Como usar

```bash
pgrep -a termux-x11 || (termux-x11 :0 &)

DISPLAY=:0 GALLIUM_DRIVER=zink LIBGL_KOPPER_DISABLE=true \
  LIBGL_DRIVERS_PATH=$HOME/mesa-zink/lib/dri \
  LD_LIBRARY_PATH=$HOME/mesa-zink/lib \
  glxgears
