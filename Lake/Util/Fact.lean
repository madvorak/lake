/-
Copyright (c) 2022 Mac Malone. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Mac Malone
-/

namespace Lake

/-- Type class synthesis of propositions. -/
class Fact (P : Prop) : Prop where
  proof : P

instance : Fact (a = a) := ⟨rfl⟩
