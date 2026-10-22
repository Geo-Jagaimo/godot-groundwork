@tool
class_name GwLog
extends RefCounted
## Import log. Messages at or above ProjectSettings [code]groundwork/log_level[/code]
## are printed; everything is written to [constant LOG_PATH] for bug reports.

enum Level { ERROR, WARN, INFO, DEBUG }

const LOG_PATH := "user://groundwork_last_import.log"
const LEVEL_SETTING := "groundwork/log_level"
const LEVEL_NAMES: Array[String] = ["ERROR", "WARN", "INFO", "DEBUG"]

var lines := PackedStringArray()
var print_level := Level.WARN
var _start_msec := 0


func _init() -> void:
	print_level = ProjectSettings.get_setting(LEVEL_SETTING, Level.WARN)
	_start_msec = Time.get_ticks_msec()


func error(message: String) -> void:
	_add(Level.ERROR, message)


func warn(message: String) -> void:
	_add(Level.WARN, message)


func info(message: String) -> void:
	_add(Level.INFO, message)


func debug(message: String) -> void:
	_add(Level.DEBUG, message)


func save(path: String = LOG_PATH) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines) + "\n")


func _add(level: Level, message: String) -> void:
	var t := (Time.get_ticks_msec() - _start_msec) / 1000.0
	lines.append("[%8.3f] %-5s %s" % [t, LEVEL_NAMES[level], message])
	if level > print_level:
		return
	match level:
		Level.ERROR:
			printerr("[Groundwork] " + message)
		Level.WARN:
			print_rich("[color=yellow][Groundwork] %s[/color]" % message)
		_:
			print("[Groundwork] " + message)
