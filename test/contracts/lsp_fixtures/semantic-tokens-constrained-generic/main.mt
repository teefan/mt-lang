interface Damageable:
    function damage(amount: int) -> int

function apply[T implements Damageable](target: ref[T], amount: int) -> int:
    return target.damage(amount)
