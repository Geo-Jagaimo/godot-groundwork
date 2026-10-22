@tool
class_name GwCancellationToken
extends RefCounted
## Cooperative cancellation shared between the caller and long-running work.

signal cancelled

var _cancelled := false


func cancel() -> void:
	if _cancelled:
		return
	_cancelled = true
	cancelled.emit()


func is_cancelled() -> bool:
	return _cancelled
