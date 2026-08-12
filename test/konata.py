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
    raw_events.sort(key=lambda event: (event[0], event_priority[event[2]], event[1]))

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
        instructions.append({"id": inst_id, "pc": pc, "bits": bits, "killed": False})
        emit(
            start_cycle,
            0,
            f"I\t{inst_id}\t{inst_id}\t0",
            f"S\t{inst_id}\t0\tF",
            f"L\t{inst_id}\t0\t{pc:016x}: {bits:08x}",
        )
        # F covers the memory request through instruction extraction.  Once
        # inserted into the issue FIFO, the instruction waits in D until X.
        emit(cycle, 1, f"S\t{inst_id}\t0\tD")
        return inst_id

    def take(queue, pc, bits, event):
        for inst_id in queue:
            inst = instructions[inst_id]
            if inst["pc"] == pc and inst["bits"] == bits and not inst["killed"]:
                queue.remove(inst_id)
                return inst_id
        print(f"konata.py: unmatched {event} at {pc:016x}: {bits:08x}", file=sys.stderr)
        return new_instruction(current_cycle, pc, bits)

    def kill(queue, cycle):
        while queue:
            inst_id = queue.popleft()
            if not instructions[inst_id]["killed"]:
                instructions[inst_id]["killed"] = True
                emit(cycle, 8, f"R\t{inst_id}\t{retire_id}\t1")

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
            emit(current_cycle, 2, f"L\t{inst_id}\t1\titype: {fields[2]}", f"S\t{inst_id}\t0\tX")
        elif kind == "A":
            tag = int(fields[0])
            pc, bits = map(number, fields[1:3])
            inst_id = take(execute, pc, bits, "allocate")
            rob[tag] = inst_id
            emit(current_cycle, 3, f"S\t{inst_id}\t0\t{'M' if int(fields[3], 2) else 'W'}")
        elif kind == "C":
            tag = int(fields[0])
            if tag in rob:
                emit(current_cycle, 4, f"S\t{rob[tag]}\t0\tW")
        elif kind == "W":
            tag = int(fields[0])
            if tag in rob:
                inst_id = rob.pop(tag)
                emit(current_cycle, 5, f"S\t{inst_id}\t0\tW", f"R\t{inst_id}\t{retire_id}\t0")
                retire_id += 1
        elif kind == "R":
            redirect_kind = fields[0]
            kill(frontend, current_cycle)
            if redirect_kind != "PRED":
                kill(execute, current_cycle)
            epoch += 1
            outstanding.clear()

    # A finite trace may stop with instructions still in the frontend.
    last_cycle = raw_events[-1][0] if raw_events else 0
    kill(frontend, last_cycle)
    kill(execute, last_cycle)

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
