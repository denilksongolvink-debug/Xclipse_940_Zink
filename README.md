Xclipse 940 Zink — Mesa 26.2.3 para Termux

Build experimental do Mesa 26.2.3 com Zink para Android/Termux, utilizando o Vulkan proprietário da Samsung/Xclipse 940.

O projeto não implementa um novo Vulkan driver. O objetivo é usar o Zink existente para traduzir OpenGL para Vulkan e utilizar o driver Vulkan proprietário já presente no dispositivo.

Arquitetura

Caminho principal

OpenGL → Mesa EGL / GLX → Zink → Android Vulkan Loader → /system/lib64/libvulkan.so → Samsung Proprietary Vulkan → Xclipse 940

Caminho DRI3 experimental

OpenGL → Zink → DRI3 / Present → Termux:X11 modificado → AHardwareBuffer / dma-buf → Android EGL / ANativeWindow → BufferQueue
---

Requisitos

- Android com GPU Samsung Xclipse 940
- Termux
- Termux:X11
- Vulkan proprietário da Samsung funcionando
- Acesso a "/system/lib64/libvulkan.so"
- Arquitetura AArch64

O script instala as dependências necessárias e compila o Mesa.

---

Build

O script principal é:

~/Xclipse-940-Zink/install-xclipse-zink.sh

Execute:

chmod +x ~/Xclipse-940-Zink/install-xclipse-zink.sh
bash ~/Xclipse-940-Zink/install-xclipse-zink.sh

Para controlar o número de jobs:

JOBS=3 bash ~/Xclipse-940-Zink/install-xclipse-zink.sh

Por padrão, os arquivos são organizados em:

$HOME/Xclipse-940-Zink/
├── mesa-26.2.3/
├── zink-install/
├── vklib/
├── termux-packages/
└── install-xclipse-zink.log

Os wrappers ficam em:

$HOME/.bin/
├── zink
└── zink-dri3

---

Patches

O build utiliza patches do pacote Mesa do Termux:

0000
0002
0003
0004
0006
0008
0011
0015
0017

Além deles, o script aplica modificações específicas ao Zink.

Zink

As principais modificações são:

- "VK_KHR_maintenance5" deixa de ser obrigatório.
- Fallback para seleção do physical device quando não há correspondência DRM direta.
- Integração de "sw_winsys"/"sw_displaytarget".
- Caminho alternativo de "flush_frontbuffer" quando não existe swapchain/Kopper.
- Suporte ao transporte de framebuffer pelo winsys do Mesa.

O objetivo dessas alterações é permitir que o Zink funcione dentro das limitações do ambiente Android/Termux.

---

Execução

Zink

Caminho principal:

~/.bin/zink glxgears

ou:

~/.bin/zink glmark2

Renderer esperado:

zink Vulkan 1.3(Samsung Xclipse 940 (SAMSUNG_PROPRIETARY))

Zink + DRI3

Caminho experimental:

~/.bin/zink-dri3 glmark2

Esse modo utiliza:

Zink → DRI3 → Termux:X11 → AHardwareBuffer/dma-buf

e requer o Termux:X11 modificado utilizado neste projeto.

---

Vulkan

O projeto utiliza o Vulkan loader do Android:

/system/lib64/libvulkan.so

O script cria:

$HOME/Xclipse-940-Zink/vklib/libvulkan.so
$HOME/Xclipse-940-Zink/vklib/libvulkan.so.1

ambos apontando para o loader do sistema.

O Zink então utiliza o driver Vulkan proprietário da Samsung, em vez de um Turnip customizado.

---

Swap / DRI3

Existe um patch opcional controlado por:

MESA_SWAP_CLAMP=1

Ele força:

swap_interval 0 → 1

em determinadas situações do caminho DRI3.

Isso foi adicionado como mecanismo experimental para reduzir problemas de apresentação quando o produtor gera buffers muito mais rapidamente do que o consumidor consegue processá-los.

O objetivo final não é limitar artificialmente o FPS.

A investigação atual está concentrada na sincronização entre:

DRI3 → Present → AHardwareBuffer → ANativeWindow → Android BufferQueue

especialmente no controle de reutilização e liberação dos buffers.

---

Estado atual

Funcionando

- Mesa 26.2.3 compilado para Termux.
- Zink carregando corretamente.
- Vulkan proprietário Samsung detectado.
- Xclipse 940 utilizado pelo Zink.
- OpenGL/OpenGL ES funcionando através do Zink.
- "glmark2" funcionando em janela X11.
- Caminho DRI3 experimental funcionando.

Renderer confirmado:

GL_VENDOR: Mesa
GL_RENDERER: zink Vulkan 1.3(Samsung Xclipse 940 (SAMSUNG_PROPRIETARY))
GL_VERSION: 4.6 (Compatibility Profile) Mesa 26.2.3

Ainda experimental

A apresentação DRI3 apresenta problemas de sincronização em cargas com FPS muito alto.

Sintomas observados:

- buffers processados fora de ordem;
- falhas/gaps na imagem;
- reutilização de buffers antes do consumo completo;
- comportamento dependente da sincronização do Present/BufferQueue.

Por isso, o "MESA_SWAP_CLAMP" existe atualmente como workaround/diagnóstico.

---

Objetivo do projeto

O objetivo final é obter:

X11 → EGL → Mesa → Zink → Samsung Vulkan → Xclipse 940

com apresentação DRI3/dma-buf corretamente sincronizada, sem depender de um limite artificial de FPS.

O foco é corrigir a sincronização dos buffers no caminho:

Mesa DRI3
 → Termux:X11
 → AHardwareBuffer
 → ANativeWindow
 → Android BufferQueue

em vez de criar um novo Vulkan driver.

---

Documentação futura

Detalhes que não fazem parte do README principal poderão ser separados em:

docs/
├── mesa-patches.md
├── dri3.md
├── xclipse-vulkan.md
└── performance.md

Esses documentos poderão conter os detalhes de implementação, diagnóstico, patches individuais e análise de performance.

---

Aviso

Este projeto é experimental e específico para o ambiente Android/Termux com Samsung Xclipse.

Não substitui o driver Vulkan proprietário da Samsung e não tem como objetivo implementar um driver Vulkan alternativo.
