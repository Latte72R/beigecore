#!/usr/bin/env python3
"""Convert local RTL pipeline events into a Konata trace.

The RTL deliberately logs no dynamic instruction ID.  This script reconstructs
instruction flow from FIFO order and ROB tags, and associates each instruction
with the 8-byte memory request that fetched it.
"""

import argparse
import collections
import sys


def number(text):
    return int(text, 16)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("raw", help="raw KTRACE log")
    args = parser.parse_args()

    raw_events = []
    with open(args.raw, encoding="utf-8") as stream:
        for order, line in enumerate(stream):
            fields = line.rstrip().split("\t")
            if len(fields) >= 3 and fields[0] == "K":
                raw_events.append((int(fields[1]), order, fields[2], fields[3:]))

    # Module $display order is unspecified.  This is the logical order within
    # one clock edge; redirects are applied after the instruction causing them.
    event_priority = {"Q": 0, "P": 1, "F": 2, "X": 3, "C": 4, "W": 5, "A": 6, "R": 7}
    raw_events.sort(key=lambda event: (event[0], event_priority.get(event[2], 99), event[1]))

    instructions = []
    frontend = collections.deque()
    execute = collections.deque()
    rob = {}
    requests = collections.defaultdict(list)
    outstanding = collections.defaultdict(collections.deque)
    epoch = 0
    output = []
    retire_id = 0

    def emit(cycle, priority, *lines):
        output.append((cycle, priority, len(output), lines))

    def new_instruction(cycle, pc, bits):
        nonlocal instructions
        block_addr = pc & ~7
        request = next(
            (
                item
                for item in reversed(requests[(epoch, block_addr)])
                if item["response"] is not None and item["response"] <= cycle and pc not in item["used"]
            ),
            None,
        )
        start_cycle = request["cycle"] if request is not None else cycle
        if request is not None:
            request["used"].add(pc)

        inst_id = len(instructions)
        instructions.append(
            {
                "id": inst_id,
                "pc": pc,
                "bits": bits,
                "alive": True,
                "stage": "F",
            }
        )
        emit(
            start_cycle,
            0,
            f"I\t{inst_id}\t{inst_id}\t0",
            f"S\t{inst_id}\t0\tF",
            f"L\t{inst_id}\t0\t{pc:016x}: {bits:08x}",
        )
        # F covers the memory request through instruction extraction.  Once
        # inserted into the issue FIFO, the instruction waits in D until X.
        transition(inst_id, cycle, 1, "D")
        return inst_id

    def transition(inst_id, cycle, priority, stage):
        """Move an instruction to a stage without emitting duplicate stages."""
        inst = instructions[inst_id]
        if not inst["alive"] or inst["stage"] == stage:
            return
        inst["stage"] = stage
        emit(cycle, priority, f"S\t{inst_id}\t0\t{stage}")

    def take(queue, pc, bits, event):
        for inst_id in queue:
            inst = instructions[inst_id]
            if inst["pc"] == pc and inst["bits"] == bits and inst["alive"]:
                queue.remove(inst_id)
                return inst_id
        print(f"konata.py: unmatched {event} at {pc:016x}: {bits:08x}", file=sys.stderr)
        return new_instruction(current_cycle, pc, bits)

    def finish(inst_id, cycle, flushed):
        nonlocal retire_id
        inst = instructions[inst_id]
        if not inst["alive"]:
            return
        inst["alive"] = False
        emit(cycle, 8, f"R\t{inst_id}\t{retire_id}\t{1 if flushed else 0}")
        if not flushed:
            retire_id += 1

    def kill(queue, cycle):
        while queue:
            inst_id = queue.popleft()
            finish(inst_id, cycle, True)

    def kill_rob(cycle):
        for inst_id in list(rob.values()):
            finish(inst_id, cycle, True)
        rob.clear()

    for current_cycle, _, kind, fields in raw_events:
        if kind == "Q":
            addr = number(fields[0])
            request = {"cycle": current_cycle, "response": None, "used": set()}
            requests[(epoch, addr)].append(request)
            outstanding[addr].append(request)
        elif kind == "P":
            addr = number(fields[0])
            if outstanding[addr]:
                outstanding[addr].popleft()["response"] = current_cycle
        elif kind == "F":
            pc, bits = map(number, fields[:2])
            frontend.append(new_instruction(current_cycle, pc, bits))
        elif kind == "X":
            pc, bits = map(number, fields[:2])
            inst_id = take(frontend, pc, bits, "X")
            execute.append(inst_id)
            emit(current_cycle, 2, f"L\t{inst_id}\t1\titype: {fields[2]}")
            transition(inst_id, current_cycle, 2, "X")
        elif kind == "A":
            tag = int(fields[0])
            pc, bits = map(number, fields[1:3])
            inst_id = take(execute, pc, bits, "allocate")
            if tag in rob and instructions[rob[tag]]["alive"]:
                print(f"konata.py: live ROB tag {tag} was reused", file=sys.stderr)
                finish(rob[tag], current_cycle, True)
            rob[tag] = inst_id
            emit(current_cycle, 3, f"L\t{inst_id}\t1\tROB tag: {tag}")
            if int(fields[3], 2):
                transition(inst_id, current_cycle, 3, "M")
        elif kind == "C":
            tag = int(fields[0])
            if tag in rob:
                transition(rob[tag], current_cycle, 4, "W")
            else:
                print(f"konata.py: completion for unknown ROB tag {tag}", file=sys.stderr)
        elif kind == "W":
            tag = int(fields[0])
            if tag in rob:
                inst_id = rob.pop(tag)
                transition(inst_id, current_cycle, 5, "W")
                finish(inst_id, current_cycle, False)
            else:
                print(f"konata.py: commit for unknown ROB tag {tag}", file=sys.stderr)
        elif kind == "R":
            redirect_kind = fields[0]
            kill(frontend, current_cycle)
            if redirect_kind != "PRED":
                kill(execute, current_cycle)
            if redirect_kind == "BACKEND":
                kill_rob(current_cycle)
            epoch += 1
            outstanding.clear()

    # A finite trace may stop with instructions still in the frontend.
    last_cycle = raw_events[-1][0] if raw_events else 0
    kill(frontend, last_cycle)
    kill(execute, last_cycle)
    kill_rob(last_cycle)

    print("Kanata\t0004")
    print("C=\t0")
    displayed_cycle = 0
    for cycle, _, _, lines in sorted(output):
        if cycle > displayed_cycle:
            print(f"C\t{cycle - displayed_cycle}")
            displayed_cycle = cycle
        print("\n".join(lines))


if __name__ == "__main__":
    main()
