@tool
extends RefCounted
## Helpers shared by the HLOD scripts.


## Returns the transform of [param node] relative to [param root] computed from local transforms, so that it
## also works for scenes that are not inside the tree (e.g. while importing). Returns null if the node is hidden,
## top level, or not below [param root].
static func relative_transform(node: Node, root: Node) -> Variant:
	var xform := Transform3D.IDENTITY
	var current := node
	while current != null and current != root:
		var node_3d := current as Node3D
		if node_3d != null:
			if not node_3d.visible or node_3d.top_level:
				return null
			xform = node_3d.transform * xform
		current = current.get_parent()
	if current != root:
		return null
	return xform


## Moves [param node] below [param new_parent] while keeping the nodes that belong to the same scene owner.
## Unsetting the owner during the move avoids the warning about temporarily inconsistent ownership.
static func move_node_keeping_owner(node: Node, new_parent: Node) -> void:
	var owner_node := node.owner
	var owned: Array[Node] = []
	if owner_node != null:
		var to_visit: Array[Node] = [node]
		while not to_visit.is_empty():
			var current: Node = to_visit.pop_back()
			if current.owner == owner_node:
				owned.append(current)
			for child in current.get_children():
				to_visit.append(child)
		for current in owned:
			current.owner = null
	node.get_parent().remove_child(node)
	new_parent.add_child(node)
	for current in owned:
		current.owner = owner_node
