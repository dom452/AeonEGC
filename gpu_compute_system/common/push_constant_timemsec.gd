extends Push_Constant
class_name PushConstant_TimeMSec
## Concrete subclass wrapping simulation uptime for injection alongside compute phases avoiding expensive external uniform buffer mutations.
## NOTE: Now returns total elapsed simulated days from GameStateManager instead of machine uptime.

func get_value() -> Variant:
	type = TYPE_FLOAT
	return float(GameStateManager.elapsed_days) + GameStateManager.day_progress
