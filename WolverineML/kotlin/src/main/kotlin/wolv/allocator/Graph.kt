/**
 * Register allocation by graph colouring, with iterated coalescing.
 *
 * The idea is Chaitin's: build a graph whose nodes are values and whose edges
 * join values that are live at the same time, then colour it with as many colours
 * as the machine has registers.  Colouring a graph is hard in general, but
 * Kempe's observation makes it practical: a node with fewer than K neighbours can
 * always be coloured whatever happens to the rest of the graph.  So remove such
 * nodes one at a time and push them on a stack; when the graph is empty, pop the
 * stack and give each node a colour its neighbours have not taken.  If every
 * remaining node has K or more neighbours, guess that one of them will not get a
 * colour and carry on — if the guess was wrong the value is rewritten to live in
 * memory and the whole thing runs again (Briggs' optimistic colouring).
 *
 * On top of that sits coalescing, which is why leaving SSA first costs nothing.
 * Leaving SSA fills the predecessors of every join with copies; coalescing merges
 * the two ends of a copy so that it disappears.  Merging aggressively can make a
 * graph uncolourable, so a merge only happens when Briggs' test proves it cannot:
 * the merged node must have fewer than K neighbours of significant degree.  That
 * test is only exact enough to be useful if degrees are up to date, and
 * simplifying lowers degrees while merging raises them — so the two run
 * interleaved, with freezing (giving up on a copy so its nodes can be simplified)
 * as the way out when neither applies.  Hence "iterated" (George and Appel, 1996).
 *
 * This machine has no fixed registers to colour against, so the calling
 * convention is carried as a set of colours each node may not take: a value live
 * across a call may not take a caller-saved one.  A node with `f` forbidden
 * colours and `d` neighbours needs `d + f < K` to be trivially colourable, so
 * that sum is what stands in for the degree everywhere below.
 */

package wolv.allocator

import wolv.ir.*
import wolv.*


/** Colour `func`, rewriting and starting again for as long as it spills. */
fun allocate(func: Func, machine: Registers) {
    val protected = mutableSetOf<Reg>()
    while (true) {
        func.recomputePreds()
        val colouring = Colouring(func, machine, protected)
        val spilled = colouring.run()
        if (spilled.isEmpty()) {
            func.colours = colouring.colour
            func.saved = func.colours.values.toSet()
                .intersect(Registers.CALLEE_SAVED.toSet()).sorted()
            return
        }
        for (victim in spilled.sorted()) {
            if (victim in protected) {
                throw OutOfRegisters(
                    "`${func.name}` needs more registers at once than the machine has",
                )
            }
            protected += spill(func, victim)
        }
    }
}

/** A copy coalescing may be able to make disappear.  Not `ir.Move`: that is
 *  the instruction, this is the candidate the worklists carry around. */
private class Copy(val dst: Reg, val src: Reg)

private class Colouring(
val func: Func,
val machine: Registers,
/**
 * Values that a previous round produced by reloading something.  Their live
 * ranges are a load and its one use, so spilling one again would only make
 * another of the same, and the rewriting would never end.
 */
val protected: Set<Reg>,
) {
val adjacent: MutableMap<Reg, MutableSet<Reg>> = LinkedHashMap()
val degree: MutableMap<Reg, Int> = mutableMapOf()
val forbidden: MutableMap<Reg, MutableSet<Int>> = mutableMapOf()
var preferred: MutableMap<Reg, Int> = mutableMapOf()

val moves: MutableList<Copy> = mutableListOf()
val movesOf: MutableMap<Reg, MutableSet<Int>> = mutableMapOf()
val worklistMoves: MutableSet<Int> = mutableSetOf()
val activeMoves: MutableSet<Int> = mutableSetOf()

val simplifyWorklist: MutableSet<Reg> = mutableSetOf()
val freezeWorklist: MutableSet<Reg> = mutableSetOf()
val spillWorklist: MutableSet<Reg> = mutableSetOf()
val selectStack: MutableList<Reg> = mutableListOf()
val onStack: MutableSet<Reg> = mutableSetOf()
val coalesced: MutableSet<Reg> = mutableSetOf()
val alias: MutableMap<Reg, Reg> = mutableMapOf()
val colour: MutableMap<Reg, Int> = mutableMapOf()

val k: Int get() = machine.count()

fun run(): Set<Reg> {
    build()
    makeWorklists()
    while (
        simplifyWorklist.isNotEmpty() || worklistMoves.isNotEmpty() ||
        freezeWorklist.isNotEmpty() || spillWorklist.isNotEmpty()
    ) {
        when {
            simplifyWorklist.isNotEmpty() -> simplify()
            worklistMoves.isNotEmpty() -> coalesce()
            freezeWorklist.isNotEmpty() -> freeze()
            else -> selectSpill()
        }
    }
    return assignColours()
}

// -- the graph --------------------------------------------------------

fun node(r: Reg) {
    adjacent.getOrPut(r) { mutableSetOf() }
    degree.putIfAbsent(r, 0)
    forbidden.getOrPut(r) { mutableSetOf() }
}

fun addEdge(a: Reg, b: Reg) {
    if (a == b || b in adjacent.getValue(a)) return
    adjacent.getValue(a).add(b)
    adjacent.getValue(b).add(a)
    degree[a] = degree.getValue(a) + 1
    degree[b] = degree.getValue(b) + 1
}

/** The degree, counting a forbidden colour as a neighbour holding it. */
fun weight(r: Reg): Int = degree.getValue(r) + forbidden.getValue(r).size

fun build() {
    preferred = preferences(func)
    val live = func.liveness()
    val callerSaved = machine.caller.toSet()
    for (block in func.walk()) {
        for (instr in block.instrs) {
            for (r in instr.uses) node(r)
            instr.def?.let { node(it) }
        }
    }
    for (r in func.params) node(r)

    for (block in func.walk()) {
        val alive = live.liveOut.getValue(block.label).toMutableSet()
        for (instr in block.instrs.asReversed()) {
            if (instr is Move) {
                alive.remove(instr.src)
                val index = moves.size
                moves.add(Copy(instr.dst, instr.src))
                movesOf.getOrPut(instr.dst) { mutableSetOf() }.add(index)
                movesOf.getOrPut(instr.src) { mutableSetOf() }.add(index)
                worklistMoves.add(index)
            }
            val defined = instr.def
            if (defined != null) {
                alive.add(defined)
                for (other in alive) addEdge(defined, other)
            }
            if (instr is Call) {
                for (r in alive) if (r != defined) forbidden.getValue(r).addAll(callerSaved)
            }
            if (defined != null) alive.remove(defined)
            alive.addAll(instr.uses)
        }
        if (block.label == func.entry) entryEdges(alive)
    }
}

/** Parameters arrive together, so they interfere with each other. */
fun entryEdges(alive: Set<Reg>) {
    for ((i, param) in func.params.withIndex()) {
        for (other in alive) addEdge(param, other)
        for (another in func.params.drop(i + 1)) addEdge(param, another)
    }
}

// -- the worklists ----------------------------------------------------

fun makeWorklists() {
    for (r in adjacent.keys.sorted()) {
        when {
            weight(r) >= k -> spillWorklist.add(r)
            moveRelated(r) -> freezeWorklist.add(r)
            else -> simplifyWorklist.add(r)
        }
    }
}

fun nodeMoves(r: Reg): Set<Int> =
    movesOf[r]?.filterTo(mutableSetOf()) { it in activeMoves || it in worklistMoves } ?: setOf()

fun moveRelated(r: Reg): Boolean = nodeMoves(r).isNotEmpty()

fun neighbours(r: Reg): Set<Reg> = adjacent.getValue(r) - onStack - coalesced

fun simplify() {
    val r = simplifyWorklist.min()
    simplifyWorklist.remove(r)
    selectStack.add(r)
    onStack.add(r)
    for (other in neighbours(r).sorted()) decrementDegree(other)
}

fun decrementDegree(r: Reg) {
    val was = weight(r)
    degree[r] = degree.getValue(r) - 1
    if (was != k) return
    // It has just become trivially colourable, so the copies around it may
    // have become safe to merge as well.
    enableMoves(neighbours(r) + r)
    spillWorklist.remove(r)
    if (moveRelated(r)) freezeWorklist.add(r) else simplifyWorklist.add(r)
}

fun enableMoves(nodes: Set<Reg>) {
    for (r in nodes) {
        for (index in nodeMoves(r).toList()) {
            if (activeMoves.remove(index)) worklistMoves.add(index)
        }
    }
}

// -- coalescing -------------------------------------------------------

fun getAlias(start: Reg): Reg {
    var r = start
    while (r in coalesced) r = alias.getValue(r)
    return r
}

fun coalesce() {
    val index = worklistMoves.min()
    val move = moves[index]
    worklistMoves.remove(index)
    val u = getAlias(move.dst)
    val v = getAlias(move.src)
    when {
        u == v -> addToWorklist(u)
        v in adjacent.getValue(u) -> {
            addToWorklist(u)
            addToWorklist(v)
        }
        conservative(u, v) -> {
            combine(u, v)
            addToWorklist(u)
        }
        else -> activeMoves.add(index)
    }
}

fun addToWorklist(r: Reg) {
    if (weight(r) < k && !moveRelated(r)) {
        freezeWorklist.remove(r)
        simplifyWorklist.add(r)
    }
}

/**
 * Briggs: the merged node must have fewer than K significant neighbours.
 *
 * The colours the two ends may not take add up as well, and a colour the
 * merged node is barred from is one more thing standing in its way.
 */
fun conservative(u: Reg, v: Reg): Boolean {
    val together = neighbours(u) + neighbours(v)
    val barred = (forbidden.getValue(u) + forbidden.getValue(v)).size
    val significant = together.count { weight(it) >= k }
    return significant + barred < k
}

fun combine(u: Reg, v: Reg) {
    freezeWorklist.remove(v)
    spillWorklist.remove(v)
    coalesced.add(v)
    alias[v] = u
    movesOf.getOrPut(u) { mutableSetOf() }.addAll(movesOf[v] ?: setOf())
    forbidden.getValue(u).addAll(forbidden.getValue(v))
    if (v in preferred && u !in preferred) preferred[u] = preferred.getValue(v)
    enableMoves(setOf(v))
    for (other in neighbours(v).sorted()) {
        addEdge(other, u)
        decrementDegree(other)
    }
    if (weight(u) >= k && u in freezeWorklist) {
        freezeWorklist.remove(u)
        spillWorklist.add(u)
    }
}

// -- freezing and spilling --------------------------------------------

fun freeze() {
    val r = freezeWorklist.min()
    freezeWorklist.remove(r)
    simplifyWorklist.add(r)
    freezeMoves(r)
}

fun freezeMoves(r: Reg) {
    for (index in nodeMoves(r).toList()) {
        val move = moves[index]
        activeMoves.remove(index)
        worklistMoves.remove(index)
        val other = getAlias(
            if (getAlias(move.dst) == getAlias(r)) move.src else move.dst,
        )
        if (!moveRelated(other) && weight(other) < k) {
            freezeWorklist.remove(other)
            simplifyWorklist.add(other)
        }
    }
}

/**
 * Guess that the value with the most neighbours per use will not fit.
 *
 * Never a reload, though: those are cheap by that measure precisely because
 * they were made cheap, and choosing one would undo the last round's work
 * instead of the pressure.
 */
fun selectSpill() {
    val weights = costs(func)
    val among = (spillWorklist - protected).sorted().ifEmpty { spillWorklist.sorted() }
    val chosen = among.maxBy { weight(it) / ((weights[it] ?: 0.0) + 1.0) }
    spillWorklist.remove(chosen)
    simplifyWorklist.add(chosen)
    freezeMoves(chosen)
}

// -- handing out the colours ------------------------------------------

fun assignColours(): Set<Reg> {
    val spilled = mutableSetOf<Reg>()
    while (selectStack.isNotEmpty()) {
        val r = selectStack.removeAt(selectStack.size - 1)
        onStack.remove(r)
        val taken = adjacent.getValue(r).mapNotNull { colour[getAlias(it)] }.toSet()
        val free = machine.anywhere.filter { it !in taken && it !in forbidden.getValue(r) }
        if (free.isEmpty()) {
            spilled.add(r)
            continue
        }
        val want = preferred[r]
        colour[r] = if (want != null && want in free) want else free[0]
    }
    for (r in coalesced.sorted()) {
        colour[r] = colour[getAlias(r)] ?: machine.anywhere[0]
    }
    return spilled
}
}
