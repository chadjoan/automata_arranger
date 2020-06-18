# Automata Arranger

Data structures for representing finite automata and an NFA->DFA converter.

This project is under construction and, for now, has a few major components missing.

The plan is to have a library that provides reasonably fast (cache friendly,
low algorithmic complexity, few or no unnecessary heap+GC allocations)
data structures and algorithms for doing very basic operations on finite
automata such as the NFAs and DFAs used to implement regular expressions.

The first milestone/target is to be able to run an experiment where all
possible regular expressions (up to an configurable length or complexity)
are compiled into DFAs, then sorted by ratio of NFA nodes to DFA nodes, and
a report generated that would show which regular expressions (or classes of
regular expressions) cause an exponential explosion in node count under
DFA conversion (or even other undesirably complex increases, including
superlinear polynomial complexities (ex: quadratic, cubic, quartic, etc)).
This *might* make it easier to identify hazardous input in-flight and use
hybrid DFA-NFA output (and various NFA optimizations) to balance the
computational complexity and space complexity of compiled regular expression.

(I have thus far been able to find *examples* of expressions and NFAs that
compile into absurdly large DFAs, but no indication as to whether these are
the only ones possible, or as to what classes of expressions cause this.
Basically, I want to be able to precisely differentiate between pathological
and non-pathological inputs, with false negatives considered especially bad,
and false positives not much better.)

Past that milestone, this library should become a useful component in other
projects that I am working on. The major one is a parser generator that can
use hybrid grammars made of both Parsing Expression Grammars (PEGs) and
Regular Expressions by compiling them into very efficient DFA+packrat
hybrid parsers that execute as native machine code.

