# Limits of the reconstruction (Section 9.6 of the paper), first category: the program
# is typable only with an interface that is not below the coverage. The process sends
# itself :later and then only reads :go. Declared with `$interface :go or :later` it is
# well typed (the message :later stays in the mailbox). The reconstructed interface
# contains only messages that some receive of the process selects: it is :go, and the
# checking step rejects the self-send.
# Expected: rejected on the line marked "error:".
# mode: reconstruct

$self_interface none()

p = spawn(fn ->
  send(self(), :later)        # error: :later is not in the reconstructed interface :go
  receive do
    :go -> :ok
  end
end)
send(p, :go)

# The same process, declared: accepted.
$interface :go or :later
q = spawn(fn ->
  send(self(), :later)
  receive do
    :go -> :ok
  end
end)
send(q, :go)
