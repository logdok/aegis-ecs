@tool
extends EditorPlugin

## The plugin entry point — deliberately empty.
##
## Aegis ECS is a library of classes, not an editor tool: it adds no docks, no
## buttons and no importers, so there is nothing to enable or disable here.
##
## Every add-on class is declared with `class_name`, and Godot registers such
## classes globally simply by finding the file in the project — regardless of
## whether the plugin is enabled in "Project → Project Settings → Plugins". So
## the library works as soon as the folder is copied into a project, and
## `plugin.cfg` itself only exists so the add-on shows up in the plugin list and
## carries a version.
