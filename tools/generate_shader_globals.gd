@tool
extends EditorScript

## Editor script that generates global shader uniforms from Helpers layer maps.
## Automatically updates ProjectSettings and registers uniforms with RenderingServer.
##
## Usage in Godot Editor:
## Open this script in the Script Editor and select File -> Run (or press Ctrl+Shift+X).

func _run() -> void:
	sync_helpers_shader_globals()

func sync_helpers_shader_globals() -> void:
	var project_changed: bool = false
	var valid_uniforms: Dictionary[String, int] = {}

	# 1. Gather Float Layer Globals (Prefix: F_)
	var float_indices_map: Dictionary[Helpers.sim_layers, PackedInt32Array] = Helpers.create_float_layer_indices_map()
	_process_layer_map(float_indices_map, Helpers.float_sub_layer_names, "F_", valid_uniforms)

	# 2. Gather Atomic Layer Globals (Prefix: A_)
	var atomic_indices_map: Dictionary[Helpers.sim_layers, PackedInt32Array] = Helpers.create_atomic_layer_indices_map()
	_process_layer_map(atomic_indices_map, Helpers.atomic_sub_layer_names, "A_", valid_uniforms)

	# 3. Register or Update in ProjectSettings and RenderingServer
	var rs_list: Array[StringName] = RenderingServer.global_shader_parameter_get_list()

	for uniform_name: String in valid_uniforms:
		var index_value: int = valid_uniforms[uniform_name]
		var setting_path: String = "shader_globals/" + uniform_name
		var param_data: Dictionary[String, Variant] = {
			"type": "int",
			"value": index_value
		}

		# Check if setting is missing or updated
		if not ProjectSettings.has_setting(setting_path) or ProjectSettings.get_setting(setting_path) != param_data:
			ProjectSettings.set_setting(setting_path, param_data)
			project_changed = true

		# Sync with RenderingServer for immediate viewport/shader update
		var uniform_sn: StringName = StringName(uniform_name)
		if rs_list.has(uniform_sn):
			RenderingServer.global_shader_parameter_set(uniform_sn, index_value)
		else:
			RenderingServer.global_shader_parameter_add(uniform_sn, RenderingServer.GLOBAL_VAR_TYPE_INT, index_value)

		print("Synced global shader uniform: ", uniform_name, " = ", index_value)

	# 4. Clean up orphaned global uniforms starting with F_ or A_ that no longer exist in Helpers
	var active_rs_globals: Array[StringName] = RenderingServer.global_shader_parameter_get_list()
	for global_name_sn: StringName in active_rs_globals:
		var global_name: String = String(global_name_sn)
		if (global_name.begins_with("F_") or global_name.begins_with("A_")) and not valid_uniforms.has(global_name):
			print("Removing orphaned global shader uniform: ", global_name)
			RenderingServer.global_shader_parameter_remove(global_name_sn)
			var setting_path: String = "shader_globals/" + global_name
			if ProjectSettings.has_setting(setting_path):
				ProjectSettings.set_setting(setting_path, null)
				project_changed = true

	# 5. Persist changes to project.godot if modified
	if project_changed:
		ProjectSettings.save()
		var editor_iface: EditorInterface = get_editor_interface()
		if editor_iface:
			editor_iface.save_project_settings()
		ProjectSettings.notify_property_list_changed()
		print("Project Settings saved successfully with updated shader globals.")
	else:
		print("Shader globals are up to date. No changes needed.")

	# 6. Update layer_globals.gdshaderinc
	_update_gdshaderinc_file(valid_uniforms)

func _update_gdshaderinc_file(valid_uniforms: Dictionary[String, int]) -> void:
	var path: String = "res://_assets/layer_globals.gdshaderinc"
	
	var float_lines: Array[String] = []
	var atomic_lines: Array[String] = []
	
	for uniform_name: String in valid_uniforms.keys():
		var line: String = "global uniform int " + uniform_name + ";"
		if uniform_name.begins_with("F_"):
			float_lines.append(line)
		elif uniform_name.begins_with("A_"):
			atomic_lines.append(line)
			
	var new_content: String = "\n".join(float_lines) + "\n\n" + "\n".join(atomic_lines) + "\n"
	
	var existing_content: String = ""
	if FileAccess.file_exists(path):
		var file_read: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file_read:
			existing_content = file_read.get_as_text()
			file_read.close()
			
	if existing_content != new_content:
		var file_write: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if file_write:
			file_write.store_string(new_content)
			file_write.close()
			print("Updated layer_globals.gdshaderinc file.")
		else:
			printerr("Failed to open file for writing: ", path)
	else:
		print("layer_globals.gdshaderinc file is up to date.")

func _process_layer_map(
	indices_map: Dictionary[Helpers.sim_layers, PackedInt32Array],
	names_dict: Dictionary[Helpers.sim_layers, PackedStringArray],
	prefix: String,
	out_uniforms: Dictionary[String, int]
) -> void:
	for sl: Helpers.sim_layers in indices_map.keys():
		if sl < 0:
			continue
		var layer_caps: String = _get_layer_name_caps(sl)
		if layer_caps.is_empty():
			continue

		var indices: PackedInt32Array = indices_map[sl]
		var sub_names: PackedStringArray = names_dict.get(sl, PackedStringArray())

		for i: int in range(indices.size()):
			if i >= sub_names.size():
				break
			var raw_sub_name: String = sub_names[i]
			var pascal_sub_name: String = _to_pascal_case(raw_sub_name)
			var uniform_name: String = prefix + layer_caps + "_" + pascal_sub_name
			out_uniforms[uniform_name] = indices[i]

func _get_layer_name_caps(sl: Helpers.sim_layers) -> String:
	var keys: Array = Helpers.sim_layers.keys()
	var values: Array = Helpers.sim_layers.values()
	var idx: int = values.find(sl)
	if idx != -1:
		return String(keys[idx])
	return ""

func _to_pascal_case(text: String) -> String:
	var cleaned: String = text.replace(".", "_")
	var parts: PackedStringArray = cleaned.split("_", false)
	var pascal_str: String = ""
	for part: String in parts:
		if part.is_empty():
			continue
		pascal_str += part.capitalize()
	return pascal_str
