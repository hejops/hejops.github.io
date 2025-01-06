---
title: Finding data races in a Go AST
description:
date: 2025-01-06
taxonomies:
  tags: [go, ast, concurrency]
---

It is generally agreed that one of Go's major selling points is its first class
support for concurrency.
However, the implicit mutability of structs remains a source of subtle footguns.
At `$DAYJOB`, we were bitten by a data race that had unwittingly made its way
into in our backend towards the end of last year.
In its simplest form, the data race looked like this:

```go
// main.go
package main

import (
	"sync"
)

type (
	Query struct {
		// ints are used for simplicity; in reality we use time.Time
		Start int
		End   int
	}
)

func (q *Query) setInterval(start int, step int) {
	q.Start = start
	q.End = start + step
}

func queryDB(_ Query) int {
	// the actual db query would look something like this
	// rows, err := db.Query(
	// 	`SELECT * FROM entries
	// 	WHERE start >= ? AND end < ?`,
	// 	q.Start,
	// 	q.End,
	// )

	// since we don't have a DB connection, we just return a dummy int
	return 0
}

func queryDBParallel() []int {
	query := Query{}

	var wg sync.WaitGroup

	// let's say we want to get 10 arbitrary units of data, in intervals of 1
	step := 1
	results := make([]int, 10)
	for start := range 10 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			query.setInterval(i, step)
			results[i] = queryDB(query)
		}(start)
	}
	wg.Wait()

	return results
}

func main() {
	queryDBParallel()
}
```

The concurrency had been introduced a few months prior in an attempt to optimise
database queries; the results of the multiple queries would simply be
concatenated before being returned to clients.
However, when clients started reporting that they were occasionally receiving
duplicate array elements, it was a sign that something had gone wrong.
It took a few perplexed discussions to notice that the same `query` variable
(captured from the outer scope) is both written to and read from concurrently.
[Non-deterministic scheduling][sched] meant that there was a slim but non-zero
possibility of two different goroutines performing the same database reads at
the same time.
No wonder the data race was exceptionally hard for us to reproduce outside
production.

Once we understood what was causing the data race, the simplest way to prevent
it looked something like this:

<!--
```diff
-		go func(i int) {
-			defer wg.Done()
-			query.setInterval(i, step)
-			results[i] = queryDB(query)
-		}(start)
+		q := query // copies are relatively cheap in our case
+		q.setInterval(start, step)
+		go func(q Query) {
+			defer wg.Done()
+			results[start] = queryDB(q)
+		}(q)
```
-->

```go
func queryDBParallelSafe() []int {
	query := Query{}

	var wg sync.WaitGroup

	step := 1
	results := make([]int, 10)
	for start := range 10 {
		wg.Add(1)
		q := query // copies are relatively cheap in our case
		q.setInterval(start, step)
		go func(q Query) {
			defer wg.Done()
			results[start] = queryDB(q)
		}(q)
	}
	wg.Wait()

	return results
}
```

Go has excellent [built-in tooling][tool] for detecting data races, and you can
run `go run -race main.go` to verify that a data race occurs in
`queryDBParallel` version but not `queryDBParallelSafe`.
However, we didn't exactly have the luxury of just running the data race
detector locally at the time, because the larger function that housed the
spurious code was fairly monolithic.
As a thought experiment, I wondered if it was possible to detect data races
through static analysis.
After spending some time learning about AST parsing with [ast][ast], I managed
to hack together a low-budget static check:

```go
// parse.go

package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"slices"
)

func parseFile(fname string) {
	fset := token.NewFileSet()
	b, _ := os.ReadFile(fname)

	node, err := parser.ParseFile(fset, "", b, parser.AllErrors)
	if err != nil {
		return
	}

	type GoStmt struct {
		Params      []*ast.Field
		Assigns     map[token.Pos]*ast.AssignStmt
		RacyAssigns []token.Pos
	}

	var goStmts []GoStmt

	maybeRacy := func(n ast.Node) bool {
		if goStmt, ok := n.(*ast.GoStmt); ok {
			var g GoStmt
			g.Assigns = make(map[token.Pos]*ast.AssignStmt)
			call := goStmt.Call.Fun.(*ast.FuncLit)
			g.Params = call.Type.Params.List
			for _, stmt := range call.Body.List {
				if assign, ok := stmt.(*ast.AssignStmt); ok {
					if assign.Tok.String() == "=" {
						g.Assigns[assign.TokPos] = assign
					}
				}
			}
			goStmts = append(goStmts, g)

		}
		return true
	}

	ast.Inspect(node, maybeRacy)

	for _, g := range goStmts {

		var paramNames []string
		for _, p := range g.Params {
			paramNames = append(paramNames, p.Names[0].Name)
		}

		for _, a := range g.Assigns {

			for _, rhs := range a.Rhs {
				// rhs can be a simple Ident: foo = x
				// or a CallExpr: foo = fn(x)
				//
				// in either case, if x was not passed directly
				// via go func(...){...}(x), we assume that x
				// came from the outer scope, and mark the
				// whole goStmt as unsafe

				switch rtype := rhs.(type) {
				case *ast.Ident:
					if !slices.Contains(paramNames, types.ExprString(rhs)) {
						g.RacyAssigns = append(g.RacyAssigns, a.TokPos)
					}
				case *ast.CallExpr:
					// need rtype to access Args
					for _, arg := range rtype.Args {
						if !slices.Contains(paramNames, types.ExprString(arg)) {
							g.RacyAssigns = append(g.RacyAssigns, a.TokPos)
						}
					}
				default:
					panic("Unhandled rhs type in assignment")
				}
			}
		}

		if len(g.RacyAssigns) > 0 {
			fmt.Println("Racy assignment(s) found in goroutine:")
			for _, a := range g.RacyAssigns {
				fmt.Printf(
					"%s:%d:%v = %v\n",
					fname,
					fset.Position(a).Line,
					types.ExprString(g.Assigns[a].Lhs[0]),
					types.ExprString(g.Assigns[a].Rhs[0]),
				)
			}
		}

	}
}
```

When running the check on both versions of our concurrent code
(`parseFile("main.go")`), only the racy one gets reported:

```text
Racy assignment(s) found in goroutine:
main.go:46:results[i] = queryDB(query)
```

This check operates on the (admittedly flimsy) heuristic that the only safe
goroutine is a "pure" one.
That is to say, any operand of an assignment (=, not :=, which is a declaration)
can only have been explicitly passed as an argument to the goroutine, and not
implicitly (e.g. some variable captured from the outer scope).
This heuristic is unlikely to hold for anything but the simplest of goroutines,
so it probably shouldn't be used in real production code.
Still, in principle, keeping the surface area of a goroutine as small as
possible is probably sound anyway, and such a check might help steer our
codebase in this direction.

<!-- [1]: https://eli.thegreenplace.net/2022/parent-links-in-go-asts/ -->

[sched]: https://www.ardanlabs.com/blog/2018/08/scheduling-in-go-part2.html
[tool]: https://go.dev/doc/articles/race_detector
[ast]: https://blog.microfast.ch/refactoring-go-code-using-ast-replacement-e3cbacd7a331
