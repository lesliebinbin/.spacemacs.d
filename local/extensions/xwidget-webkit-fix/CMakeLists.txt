cmake_minimum_required(VERSION 3.16)
project(xwidget_webkit_fix C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK3 REQUIRED gtk+-3.0)

find_path(EMACS_MODULE_H_DIR emacs-module.h
    PATHS
    /usr/local/include
    /usr/include
)

if (NOT EMACS_MODULE_H_DIR)
    message(FATAL_ERROR "Could not find emacs-module.h")
endif()

include_directories(
    ${EMACS_MODULE_H_DIR}
    ${GTK3_INCLUDE_DIRS}
)

add_library(xwidget_webkit_fix MODULE
    src/xwidget_webkit_fix.c
)

target_link_libraries(xwidget_webkit_fix PRIVATE
    ${GTK3_LIBRARIES}
    ${CMAKE_DL_LIBS}
)

set_target_properties(xwidget_webkit_fix PROPERTIES
    PREFIX ""
    OUTPUT_NAME "xwidget_webkit_fix"
)

# Install into <prefix>/xwidget_webkit_fix/xwidget_webkit_fix.so
install(TARGETS xwidget_webkit_fix
    DESTINATION xwidget_webkit_fix
)
