set(glasswobbly_SOURCES
    main.cpp
    wobblywindows.cpp
)

kconfig_add_kcfg_files(glasswobbly_SOURCES
    wobblywindowsconfig.kcfgc
)

add_library(glass_wobbly MODULE ${glasswobbly_SOURCES})
target_include_directories(glass_wobbly PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_link_libraries(glass_wobbly PRIVATE
    KWin::kwin
    KF6::ConfigGui
)
if(GLASS_KWIN_67)
    target_compile_definitions(glass_wobbly PRIVATE GLASS_KWIN_67)
endif()
if(GLASS_KWIN_68)
    target_compile_definitions(glass_wobbly PRIVATE GLASS_KWIN_68)
endif()
install(TARGETS glass_wobbly DESTINATION ${KDE_INSTALL_PLUGINDIR}/kwin/effects/plugins)
