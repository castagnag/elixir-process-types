# Reconstruction: a closure sent to a received pid. Section 9.6 of the paper gives this
# branch as a case in which the reconstructed interface is too large, because the
# definition of the extrema (Definition def:recon-elim) reads only the bounds of a type
# variable itself, and the receive of the closure constrains its input decoration α
# through a refinement: α ∧ {:int, term()} ≤ {ζ₁, ζ₂}. This implementation reads the
# bounds in the normal form of the constraints, where this one is the bound
# α ≤ {ζ₁, ζ₂} ∨ ¬{:int, term()} (as Definition def:recon-demand does for capture
# variables): the interface says that p accepts closures that run where the :int
# messages carry integers, and the checking step accepts it.
# Expected: accepted.
# mode: reconstruct
# interface (line 16): {:job, pid((-> integer())@[none(), not {:int, not integer()}])}

$self_interface none()

shipper = spawn(fn ->
  receive do
    {:job, p} -> send(p, fn -> receive do {:int, n} -> n + 1 end end)
  end
end)

# A process that runs the closures it receives, where :int messages carry integers.
$type runner = {:int, integer()} or (-> integer()) @ runner
$interface runner
r = spawn(fn ->
  receive do
    {:int, n} -> n
    f when is_function(f) -> f.()
  end
end)

send(shipper, {:job, r})
