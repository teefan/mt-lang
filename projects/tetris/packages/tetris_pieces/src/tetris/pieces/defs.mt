public const piece_i: int = 1
public const piece_j: int = 2
public const piece_l: int = 3
public const piece_o: int = 4
public const piece_s: int = 5
public const piece_t: int = 6
public const piece_z: int = 7

public struct Cell:
    x: int
    y: int

public struct Piece:
    kind: int
    rotation: int
    x: int
    y: int

const cells_i_0: array[Cell, 4] = array[Cell, 4](
    Cell(x = 0, y = 1),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1),
    Cell(x = 3, y = 1)
)
const cells_i_1: array[Cell, 4] = array[Cell, 4](
    Cell(x = 2, y = 0),
    Cell(x = 2, y = 1),
    Cell(x = 2, y = 2),
    Cell(x = 2, y = 3)
)
const cells_j_0: array[Cell, 4] = array[Cell, 4](
    Cell(x = 0, y = 0),
    Cell(x = 0, y = 1),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1)
)
const cells_j_1: array[Cell, 4] = array[Cell, 4](
    Cell(x = 1, y = 0),
    Cell(x = 2, y = 0),
    Cell(x = 1, y = 1),
    Cell(x = 1, y = 2)
)
const cells_j_2: array[Cell, 4] = array[Cell, 4](
    Cell(x = 0, y = 1),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1),
    Cell(x = 2, y = 2)
)
const cells_j_3: array[Cell, 4] = array[Cell, 4](
    Cell(x = 1, y = 0),
    Cell(x = 1, y = 1),
    Cell(x = 0, y = 2),
    Cell(x = 1, y = 2)
)
const cells_l_0: array[Cell, 4] = array[Cell, 4](
    Cell(x = 2, y = 0),
    Cell(x = 0, y = 1),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1)
)
const cells_l_1: array[Cell, 4] = array[Cell, 4](
    Cell(x = 1, y = 0),
    Cell(x = 1, y = 1),
    Cell(x = 1, y = 2),
    Cell(x = 2, y = 2)
)
const cells_l_2: array[Cell, 4] = array[Cell, 4](
    Cell(x = 0, y = 1),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1),
    Cell(x = 0, y = 2)
)
const cells_l_3: array[Cell, 4] = array[Cell, 4](
    Cell(x = 0, y = 0),
    Cell(x = 1, y = 0),
    Cell(x = 1, y = 1),
    Cell(x = 1, y = 2)
)
const cells_o: array[Cell, 4] = array[Cell, 4](
    Cell(x = 1, y = 0),
    Cell(x = 2, y = 0),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1)
)
const cells_s_0: array[Cell, 4] = array[Cell, 4](
    Cell(x = 1, y = 0),
    Cell(x = 2, y = 0),
    Cell(x = 0, y = 1),
    Cell(x = 1, y = 1)
)
const cells_s_1: array[Cell, 4] = array[Cell, 4](
    Cell(x = 1, y = 0),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1),
    Cell(x = 2, y = 2)
)
const cells_t_0: array[Cell, 4] = array[Cell, 4](
    Cell(x = 1, y = 0),
    Cell(x = 0, y = 1),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1)
)
const cells_t_1: array[Cell, 4] = array[Cell, 4](
    Cell(x = 1, y = 0),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1),
    Cell(x = 1, y = 2)
)
const cells_t_2: array[Cell, 4] = array[Cell, 4](
    Cell(x = 0, y = 1),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1),
    Cell(x = 1, y = 2)
)
const cells_t_3: array[Cell, 4] = array[Cell, 4](
    Cell(x = 1, y = 0),
    Cell(x = 0, y = 1),
    Cell(x = 1, y = 1),
    Cell(x = 1, y = 2)
)
const cells_z_0: array[Cell, 4] = array[Cell, 4](
    Cell(x = 0, y = 0),
    Cell(x = 1, y = 0),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1)
)
const cells_z_1: array[Cell, 4] = array[Cell, 4](
    Cell(x = 2, y = 0),
    Cell(x = 1, y = 1),
    Cell(x = 2, y = 1),
    Cell(x = 1, y = 2)
)


public function shape_cells(kind: int, rotation: int) -> array[Cell, 4]:
    let spin = rotation % 4

    if kind == piece_i:
        if spin == 0 or spin == 2:
            return cells_i_0
        return cells_i_1

    if kind == piece_j:
        if spin == 0:
            return cells_j_0
        else if spin == 1:
            return cells_j_1
        else if spin == 2:
            return cells_j_2
        return cells_j_3

    if kind == piece_l:
        if spin == 0:
            return cells_l_0
        else if spin == 1:
            return cells_l_1
        else if spin == 2:
            return cells_l_2
        return cells_l_3

    if kind == piece_o:
        return cells_o

    if kind == piece_s:
        if spin == 0 or spin == 2:
            return cells_s_0
        return cells_s_1

    if kind == piece_t:
        if spin == 0:
            return cells_t_0
        else if spin == 1:
            return cells_t_1
        else if spin == 2:
            return cells_t_2
        return cells_t_3

    if spin == 0 or spin == 2:
        return cells_z_0
    return cells_z_1


extending Piece:
    public static function default() -> Piece:
        return Piece(kind = piece_t, rotation = 0, x = 3, y = 0)
