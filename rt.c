#define EGL_EGLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdio.h>
int main(void){
  EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  EGLint maj, min;
  if(!eglInitialize(d,&maj,&min)){printf("init fail\n");return 1;}
  eglBindAPI(EGL_OPENGL_ES_API);
  EGLint ca[]={EGL_SURFACE_TYPE,0,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,EGL_NONE};
  EGLConfig c; EGLint n;
  eglChooseConfig(d,ca,&c,1,&n);
  printf("configs: %d (err 0x%x)\n",n,eglGetError());
  EGLint xa[]={EGL_CONTEXT_CLIENT_VERSION,2,EGL_NONE};
  EGLContext x=eglCreateContext(d,c,EGL_NO_CONTEXT,xa);
  printf("ctx: %p (err 0x%x)\n",(void*)x,eglGetError());
  if(!eglMakeCurrent(d,EGL_NO_SURFACE,EGL_NO_SURFACE,x)){printf("makecurrent fail (err 0x%x)\n",eglGetError());return 1;}
  printf("renderer: %s\n",glGetString(GL_RENDERER));
  GLuint fbo,tex;
  glGenTextures(1,&tex); glBindTexture(GL_TEXTURE_2D,tex);
  glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,64,64,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
  glGenFramebuffers(1,&fbo); glBindFramebuffer(GL_FRAMEBUFFER,fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0);
  printf("fbo status: 0x%x\n",glCheckFramebufferStatus(GL_FRAMEBUFFER));
  glClearColor(1,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
  glViewport(0,0,64,64);
  const char*vs="attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}";
  const char*fs="precision mediump float;void main(){gl_FragColor=vec4(0.,1.,0.,1.);}";
  GLuint v=glCreateShader(GL_VERTEX_SHADER),f=glCreateShader(GL_FRAGMENT_SHADER);
  glShaderSource(v,1,&vs,0);glCompileShader(v);glShaderSource(f,1,&fs,0);glCompileShader(f);
  GLuint pr=glCreateProgram();glAttachShader(pr,v);glAttachShader(pr,f);glBindAttribLocation(pr,0,"p");glLinkProgram(pr);
  GLint ok=0;glGetProgramiv(pr,GL_LINK_STATUS,&ok);printf("link: %d\n",ok);
  glUseProgram(pr);
  float tri[]={-1,-1, 3,-1, -1,3};
  glEnableVertexAttribArray(0);glVertexAttribPointer(0,2,GL_FLOAT,0,0,tri);
  glDrawArrays(GL_TRIANGLES,0,3);
  unsigned char px[4]={9,9,9,9};
  glReadPixels(10,10,1,1,GL_RGBA,GL_UNSIGNED_BYTE,px);
  printf("pixel: %d %d %d %d (esperado 0 255 0 255 se o shader desenhou)\n",px[0],px[1],px[2],px[3]);
  return 0;
}
