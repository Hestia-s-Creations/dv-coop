extends "res://ships/modules/MineralProcessingUnit.gd"

# dv-coop mineral processing unit extension (M4). Design: docs/M4-OWNERSHIP.md "Ore accounting".
#
# Only a rock this machine owns is processed: processing is irreversible (the rock becomes processed cargo and is
# freed). A tracked rock entering the MPU is claimed (Own.touch "mpu") and joins `processing` once granted, if it is
# still inside. A puppet's MPU never takes anything, and other players' ships, pods and drones are never processed.
# When the MPU frees a rock we own, Own sees it leave the field disabled and sends o.eat (Own._onRockGone).

var coopWaiting = {}   # net id -> body, claimed and not yet granted

func _coopOwn():
	if ModLoader.has_meta("dvcoop"):
		return ModLoader.get_meta("dvcoop").get_node_or_null("Own")
	return null

func _coopPuppet() -> bool:
	return ship != null and is_instance_valid(ship) and ship.get("netControlled") == true

# Godot 3 calls _ready on every script level, so no super call; this runs after the stock _ready.
func _ready():
	var own = _coopOwn()
	if own != null:
		own.connect("granted", self, "_coopGranted")
		own.connect("denied", self, "_coopDenied")

func _on_MineralProcessingUnit_body_entered(body):
	if _coopPuppet():
		return
	if body != null and (body.has_meta("dvnet_puppet") or body.has_meta("dvnet_mirror")):
		return
	var own = _coopOwn()
	if own != null and body != null and body.has_meta("dvnet") and not own.touch(body, "mpu"):
		coopWaiting[body.get_meta("dvnet")] = body
		return
	._on_MineralProcessingUnit_body_entered(body)

func _on_MineralProcessingUnit_body_exited(body):
	if body != null and body.has_meta("dvnet"):
		coopWaiting.erase(body.get_meta("dvnet"))
	if processing.has(body):
		._on_MineralProcessingUnit_body_exited(body)
	var own = _coopOwn()
	if own != null and body != null and is_instance_valid(body) and body.has_meta("dvnet"):
		own.untouch(body, "mpu")

func _coopGranted(id):
	var body = coopWaiting.get(id)
	coopWaiting.erase(id)
	if body == null or not is_instance_valid(body):
		return
	var area = get_node_or_null("MineralProcessingUnit")   # the intake Area2D is our child (MineralProcessingUnit.tscn)
	if area != null and area.has_method("overlaps_body") and not area.overlaps_body(body):
		var own = _coopOwn()
		if own != null:
			own.untouch(body, "mpu")
		return
	if not processing.has(body):
		._on_MineralProcessingUnit_body_entered(body)

func _coopDenied(id, reason):
	coopWaiting.erase(id)
