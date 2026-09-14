/*
 * xwidget_webkit_fix.c - Emacs Dynamic Module
 *
 * Post-load runtime symbol hook for WebKitGTK in Emacs xwidget.
 *
 * Intercepts WebKitGTK's calls to `gtk_offscreen_window_get_type()` via GOT
 * (Global Offset Table) patching at runtime, allowing HTML5 video/audio playback
 * without requiring LD_PRELOAD or rebuilding Emacs.
 */

#define _GNU_SOURCE
#include <emacs-module.h>
#include <link.h>
#include <elf.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <gtk/gtk.h>

int plugin_is_GPL_compatible = 1;

static void **g_got_slot = NULL;
static GType (*g_orig_func)(void) = NULL;
static int g_hook_installed = 0;
static int g_hook_enabled = 0;

static GType hook_gtk_offscreen_window_get_type(void) {
    if (g_hook_enabled) {
        /* Return non-offscreen type so WebKit treats the view as onscreen */
        return gtk_button_get_type();
    }
    if (g_orig_func) {
        return g_orig_func();
    }
    return GTK_TYPE_WINDOW;
}

static int phdr_callback(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    (void)data;

    if (!info->dlpi_name || !strstr(info->dlpi_name, "webkit")) {
        return 0;
    }

    ElfW(Dyn) *dyn = NULL;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        if (info->dlpi_phdr[i].p_type == PT_DYNAMIC) {
            dyn = (ElfW(Dyn) *)(info->dlpi_addr + info->dlpi_phdr[i].p_vaddr);
            break;
        }
    }
    if (!dyn) return 0;

    ElfW(Rela) *rela = NULL;
    ElfW(Sym) *symtab = NULL;
    const char *strtab = NULL;
    size_t relasz = 0;

    for (ElfW(Dyn) *d = dyn; d->d_tag != DT_NULL; d++) {
        if (d->d_tag == DT_JMPREL) rela = (ElfW(Rela) *)d->d_un.d_ptr;
        else if (d->d_tag == DT_PLTRELSZ) relasz = d->d_un.d_val;
        else if (d->d_tag == DT_SYMTAB) symtab = (ElfW(Sym) *)d->d_un.d_ptr;
        else if (d->d_tag == DT_STRTAB) strtab = (const char *)d->d_un.d_ptr;
    }

    if (!rela || !symtab || !strtab) return 0;

    size_t n = relasz / sizeof(ElfW(Rela));
    for (size_t i = 0; i < n; i++) {
        unsigned int sym_idx = ELF64_R_SYM(rela[i].r_info);
        const char *name = strtab + symtab[sym_idx].st_name;
        if (strcmp(name, "gtk_offscreen_window_get_type") == 0) {
            void **slot = (void **)(info->dlpi_addr + rela[i].r_offset);
            long page_size = sysconf(_SC_PAGESIZE);
            void *page_start = (void *)((uintptr_t)slot & ~(page_size - 1));

            if (mprotect(page_start, page_size, PROT_READ | PROT_WRITE) == 0) {
                g_orig_func = (GType (*)(void))*slot;
                *slot = (void*)hook_gtk_offscreen_window_get_type;
                g_got_slot = slot;
                mprotect(page_start, page_size, PROT_READ);

                g_hook_installed = 1;
                g_hook_enabled = 1;
                return 1; // stop iteration
            }
        }
    }
    return 0;
}

static int install_got_hook(void) {
    if (g_hook_installed) {
        g_hook_enabled = 1;
        return 1;
    }
    return dl_iterate_phdr(phdr_callback, NULL);
}

/* Elisp: (xwidget-webkit-fix-enable) */
static emacs_value F_xwidget_webkit_fix_enable(emacs_env *env, ptrdiff_t nargs,
                                               emacs_value args[], void *data) {
    (void)nargs; (void)args; (void)data;
    if (install_got_hook()) {
        g_hook_enabled = 1;
        return env->intern(env, "t");
    }
    return env->intern(env, "nil");
}

/* Elisp: (xwidget-webkit-fix-disable) */
static emacs_value F_xwidget_webkit_fix_disable(emacs_env *env, ptrdiff_t nargs,
                                                emacs_value args[], void *data) {
    (void)nargs; (void)args; (void)data;
    g_hook_enabled = 0;
    return env->intern(env, "t");
}

/* Elisp: (xwidget-webkit-fix-status) */
static emacs_value F_xwidget_webkit_fix_status(emacs_env *env, ptrdiff_t nargs,
                                               emacs_value args[], void *data) {
    (void)nargs; (void)args; (void)data;
    if (g_hook_installed && g_hook_enabled) {
        return env->intern(env, "t");
    }
    return env->intern(env, "nil");
}

static void bind_function(emacs_env *env, const char *name, emacs_value Sfun) {
    emacs_value Qfset = env->intern(env, "fset");
    emacs_value Qsym = env->intern(env, name);
    emacs_value args[] = { Qsym, Sfun };
    env->funcall(env, Qfset, 2, args);
}

int emacs_module_init(struct emacs_runtime *ert) {
    emacs_env *env = ert->get_environment(ert);

    // Auto-install the hook on module load
    install_got_hook();

    emacs_value fn_enable = env->make_function(
        env, 0, 0, F_xwidget_webkit_fix_enable,
        "Enable the WebKitGTK offscreen media playback fix by hooking GOT slot.", NULL);
    bind_function(env, "xwidget-webkit-fix-enable", fn_enable);

    emacs_value fn_disable = env->make_function(
        env, 0, 0, F_xwidget_webkit_fix_disable,
        "Disable the WebKitGTK offscreen media playback fix.", NULL);
    bind_function(env, "xwidget-webkit-fix-disable", fn_disable);

    emacs_value fn_status = env->make_function(
        env, 0, 0, F_xwidget_webkit_fix_status,
        "Return t if the WebKitGTK offscreen fix is active, nil otherwise.", NULL);
    bind_function(env, "xwidget-webkit-fix-status", fn_status);

    return 0;
}
