#ifndef MT_SDL3_GL_LOADER_HELPERS_H
#define MT_SDL3_GL_LOADER_HELPERS_H

void mt_gl_use_sdl_loader(void);

#ifdef MT_SDL3_GL_LOADER_HELPERS_IMPLEMENTATION

#include <SDL3/SDL.h>

typedef void (*mtlang_gl_function)(void);
typedef mtlang_gl_function (*mtlang_gl_loader_proc)(const char *name);

void mt_gl_set_loader_proc(mtlang_gl_loader_proc loader);

void mt_gl_use_sdl_loader(void)
{
    mt_gl_set_loader_proc((mtlang_gl_loader_proc) SDL_GL_GetProcAddress);
}

#endif

#endif
