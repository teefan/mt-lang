# POC 017 — Events: event declaration (payload and no-payload), subscribe,
# subscribe_once, emit, unsubscribe.

event no_payload[8]
event with_payload[8](str)

function on_fire():
    pass

function on_payload(_msg: str):
    pass

function main() -> int:
    # subscribe
    let sub = no_payload.subscribe(on_fire)
    let _sub = sub

    let sub2 = with_payload.subscribe(on_payload)
    let _sub2 = sub2

    # subscribe_once
    let sub3 = with_payload.subscribe_once(on_payload)
    let _sub3 = sub3

    # emit
    no_payload.emit()
    with_payload.emit("hello")

    # unsubscribe
    let removed = no_payload.unsubscribe(sub.unwrap())
    let _rem = removed

    return 0
