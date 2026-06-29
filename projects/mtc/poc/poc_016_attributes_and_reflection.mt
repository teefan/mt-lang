# POC 016 — Attributes and reflection: custom attributes, @[packed], @[align],
# @[deprecated], attribute_of, has_attribute, attribute_arg[T], attributes_of,
# fields_of, members_of, size_of, align_of, offset_of, field_of, callable_of,
# field_handle.name/.type, member_handle.name/.value, static_assert.

attribute[struct] custom_attr(value: int)

@[custom_attr(42)]
@[packed]
struct Tagged:
    tag: int

@[align(16)]
struct Aligned:
    b: float

enum Fruit:
    apple
    banana

static_assert(size_of(int) == 4, "int must be 4 bytes")

function main() -> int:
    # size_of, align_of, offset_of
    let s = size_of(Tagged)
    let a = align_of(Tagged)
    let o = offset_of(Tagged, tag)
    let _s = s
    let _a = a
    let _o = o

    # has_attribute
    let hc = has_attribute(Tagged, custom_attr)
    let _hc = hc

    # attribute_of + attribute_arg[T]
    let attr = attribute_of(Tagged, custom_attr)
    let arg_val: int = attribute_arg[int](attr, value)
    let _arg = arg_val

    # attributes_of
    inline for ainfo in attributes_of(Tagged):
        pass

    # callable_of
    let ch = callable_of(main)
    let _ch = ch

    # field_of
    let fh = field_of(Tagged, tag)
    let _fh = fh

    # fields_of — iterate fields, inspect field_handle.name and .type
    inline for field in fields_of(Tagged):
        let fname = field.name
        let ftype_size = size_of(field.type)
        let _fn = fname
        let _ft = ftype_size

    # members_of — iterate members, inspect member_handle.name
    inline for member in members_of(Fruit):
        let mname = member.name
        let _mn = mname

    return 0
