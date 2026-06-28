public struct NodeIdGen:
    next_id: uint

extending NodeIdGen:
    public static function create() -> NodeIdGen:
        return NodeIdGen(next_id = 0)

    public editable function next() -> uint:
        let id = this.next_id
        this.next_id += 1
        return id

    public function count() -> uint:
        return this.next_id
