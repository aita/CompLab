// The data-flow DAG of one basic block.
//
// Instruction selection wants to see a block as expressions, not as a list: `a +
// (i << 3)` is one ARM instruction and `a + b*c` is another, and neither is
// visible while the operands are separate lines with names in between.  So each
// block is read into a graph — a node per instruction, an edge per operand — and
// the selector covers that graph with instructions.
//
// It is a graph and not a tree because a value can be read twice.  That is what
// `users` counts, and it is what decides whether a node may be folded into the
// instruction that reads it or has to become an instruction of its own: a node
// read twice would otherwise be computed twice.  A value that leaves the block
// counts as read as well, and so does one a phi in a successor names.
//
// Only pure nodes are ever folded, and only into a reader whose instruction really
// absorbs them.  Both halves matter.  Folding moves a computation to where it is
// read, which is fine for arithmetic and not fine for a load, because a store in
// between would change what it reads; and folding a chain of nodes that nothing
// absorbs would move a whole expression to its last line, leaving every value it
// read alive until then.  So the selector plans first — it asks, of each node with
// one reader, whether that reader has a tile that takes it — and everything else
// is computed where it was written.

package main

import (
	"fmt"
	"strings"
)

// noNode is what an operand holds when the value came from outside the block.
const noNode = -1

type DagNode struct {
	Index    int
	Instr    Instr
	Operands []int // a node in this block, or noNode
	Users    int
	Reader   int  // the only node that reads it, when there is one; else noNode
	Escapes  bool // read after the block ends, or by a phi in a successor
}

func (n *DagNode) value() Reg { return n.Instr.defs() }

// alone is read exactly once, inside the block, and computable where read.
func (n *DagNode) alone() bool {
	_, isBin := n.Instr.(*Bin)
	return n.Users == 1 && !n.Escapes && isBin
}

type Dag struct {
	Nodes   []*DagNode
	byValue map[Reg]int
}

func (d *Dag) of(index int) *DagNode {
	if index == noNode {
		return nil
	}
	return d.Nodes[index]
}

// rematerialisable is a constant, which costs nothing to repeat and is often not
// an instruction at all once it has become an immediate operand.
func (d *Dag) rematerialisable(index int) *DagNode {
	node := d.of(index)
	if node == nil || node.Escapes {
		return nil
	}
	if _, isConst := node.Instr.(*Const); !isConst {
		return nil
	}
	return node
}

// constant is the value at `index`, if it is one — however many read it.
//
// Even one that has to exist in a register for somebody else can be an immediate
// here, so this asks less than folding does.
func (d *Dag) constant(index int) (int64, bool) {
	node := d.of(index)
	if node == nil {
		return 0, false
	}
	if c, ok := node.Instr.(*Const); ok {
		return c.Value, true
	}
	return 0, false
}

// buildDag reads a block into a graph.  liveOut includes what the phis will read.
func buildDag(b *Block, liveOut regSet) *Dag {
	d := &Dag{byValue: map[Reg]int{}}
	for at, instr := range b.Instrs {
		uses := instr.uses()
		operands := make([]int, len(uses))
		for u, r := range uses {
			if index, ok := d.byValue[r]; ok {
				operands[u] = index
			} else {
				operands[u] = noNode
			}
		}
		node := &DagNode{Index: at, Instr: instr, Operands: operands, Reader: noNode}
		d.Nodes = append(d.Nodes, node)
		if def := instr.defs(); def != noReg {
			d.byValue[def] = at
		}
		for _, operand := range operands {
			if operand == noNode {
				continue
			}
			read := d.Nodes[operand]
			read.Users++
			if read.Users == 1 {
				read.Reader = at
			} else {
				read.Reader = noNode
			}
		}
	}
	for _, node := range d.Nodes {
		if v := node.value(); v != noReg && liveOut.has(v) {
			node.Escapes = true
		}
	}
	return d
}

func showDag(d *Dag) string {
	lines := make([]string, len(d.Nodes))
	for at, node := range d.Nodes {
		reads := make([]string, len(node.Operands))
		for o, operand := range node.Operands {
			reads[o] = "-"
			if operand != noNode {
				reads[o] = fmt.Sprint(operand)
			}
		}
		marks := ""
		if node.Escapes {
			marks += "*"
		}
		if node.Instr.hasEffect() {
			marks += "!"
		}
		lines[at] = fmt.Sprintf("  %3d%-2s %-38s reads [%s]  users %d",
			node.Index, marks, node.Instr.show(plainReg), strings.Join(reads, ", "), node.Users)
	}
	return strings.Join(lines, "\n")
}

func plainReg(r Reg) string { return fmt.Sprintf("%%%d", r) }
