#ifndef MT_GLFW_GL_LOADER_HELPERS_H
#define MT_GLFW_GL_LOADER_HELPERS_H

void mt_gl_use_glfw_loader(void);

#ifdef MT_GLFW_GL_LOADER_HELPERS_IMPLEMENTATION

#include <GLFW/glfw3.h>

typedef void (*mtlang_gl_function)(void);
typedef mtlang_gl_function (*mtlang_gl_loader_proc)(const char *name);

void mt_gl_set_loader_proc(mtlang_gl_loader_proc loader);

void mt_gl_use_glfw_loader(void)
{
    mt_gl_set_loader_proc((mtlang_gl_loader_proc) glfwGetProcAddress);
}

#endif

#endif
