extends Push_Constant
## Push constant providing elapsed simulated time in days (including fractional day progress) to a compute shader.
class_name PushConstant_TimeMSec

## Returns the total accumulated in-game days as a floating-point number.
func get_value() -> Variant:
	type = TYPE_FLOAT
	# Combine whole elapsed days with fractional day progress (1.0 = one full 24-hour cycle).
	return float(GameStateManager.elapsed_days) + GameStateManager.day_progress

