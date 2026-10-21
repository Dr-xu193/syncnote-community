# cloud_firestore 6.7.1 reads the optional bool as a pointer and never forwards
# persistence_enabled to the Firebase C++ settings. Compile a corrected copy in
# the build directory so a fresh clone gets the same fix as this machine.
get_target_property(_firestore_dir cloud_firestore_plugin SOURCE_DIR)
get_target_property(_firestore_sources cloud_firestore_plugin SOURCES)
set(_firestore_original "${_firestore_dir}/cloud_firestore_plugin.cpp")
file(READ "${_firestore_original}" _firestore_code)

set(_firestore_old
  "bool persistEnabled = pigeonApp.settings().persistence_enabled();")
set(_firestore_new
  "const bool persistEnabled = *pigeonApp.settings().persistence_enabled();\n    settings.set_persistence_enabled(persistEnabled);")
string(FIND "${_firestore_code}" "${_firestore_old}" _firestore_match)
if(_firestore_match EQUAL -1)
  message(FATAL_ERROR
    "cloud_firestore Windows settings changed. Review firestore_persistence_fix.cmake before building.")
endif()
string(REPLACE "${_firestore_old}" "${_firestore_new}"
  _firestore_code "${_firestore_code}")

set(_firestore_generated_dir "${CMAKE_CURRENT_BINARY_DIR}/generated/syncnote")
file(MAKE_DIRECTORY "${_firestore_generated_dir}")
set(_firestore_patched "${_firestore_generated_dir}/cloud_firestore_plugin.cpp")
set(_firestore_previous "")
if(EXISTS "${_firestore_patched}")
  file(READ "${_firestore_patched}" _firestore_previous)
endif()
if(NOT _firestore_code STREQUAL _firestore_previous)
  file(WRITE "${_firestore_patched}" "${_firestore_code}")
endif()

set(_firestore_build_sources)
foreach(_firestore_source IN LISTS _firestore_sources)
  get_filename_component(_firestore_name "${_firestore_source}" NAME)
  if(_firestore_name STREQUAL "cloud_firestore_plugin.cpp")
    list(APPEND _firestore_build_sources "${_firestore_patched}")
  elseif(IS_ABSOLUTE "${_firestore_source}")
    list(APPEND _firestore_build_sources "${_firestore_source}")
  else()
    list(APPEND _firestore_build_sources "${_firestore_dir}/${_firestore_source}")
  endif()
endforeach()
set_property(TARGET cloud_firestore_plugin PROPERTY SOURCES
  "${_firestore_build_sources}")
target_include_directories(cloud_firestore_plugin PRIVATE "${_firestore_dir}")
