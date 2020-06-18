/// The Tabulamaton is a finite state machine represented in a tabular format.
/// The hope is to be able to provide enough introspection and in-flight
/// metrics such that things like NFA->DFA state-complexity-explosions can be
/// detected dynamically and failover strategies applied.
/// This might also be able to batch iterations of powerset construction,
/// such that there is a decoupling between broadphase and narrowphase
/// calculations. This may provide more opportunities trade-off balancing
/// optimizations.
module tabulamaton;

struct StateNumber
{
	size_t payload;
	alias payload this;

	this(size_t num)
	{
		this.payload = num;
	}
}

struct StateSetId
{
	size_t payload;
	alias payload this;

	this(size_t id)
	{
		this.payload = id;
	}
}

struct Transition(SymbolT)
{
	StateSetId from;
	StateSetId to;
	SymbolT    on;
}

struct StateSetMember
{
	StateSetId  id;
	StateNumber number;
}

struct StateSet
{
private:
	StateSetId        id_;
	StateSetMember[]  members_;

public:
	alias members_ this;

	this(StateSetId id)
	{
		this.id_ = id;
		this.members_ = null;
	}

	this(StateSetId id, StateSetMember[] members)
	{
		this.id_ = id;
		this.members_ = members;
		if ( members.length > 0 )
			assert(members[0].id == id);
	}

	public @property StateSetId id()
	{
		return id_;
	}
}

struct Maybe(T)
{
public:
	T     payload;
	bool  exists = false;
	alias payload this;

	this(T value)
	{
		this.payload = value;
		this.exists = true;
	}

	static auto defaultValue()
	{
		typeof(this) result;
		result.exists = true;
		return result;
	}

	static auto nothing()
	{
		typeof(this) result;
		result.exists = false;
		return result;
	}
}

struct Tabulamaton(SymbolT)
{
private:
	alias Transition = Transition!SymbolT;

	Transition[]              transitionTable;

	StateSetTable             stateSets;

	bool                      transitionTableOptimized = false;

public:
	@property bool  areTablesOptimized() const {
		return stateSets.isOptimized && transitionTableOptimized;
	}

	string toCsv(/*bool nestedSets = true*/) const // Only one option for now.
	{
		static esc(string toEscape)
		{
			import std.string;
			if ( toEscape.contains('"') )
				return `"`~ replace(toEscape,`"`,`""`) ~`"`;
			else
				return toEscape;
		}

		import std.array;
		auto textOut = appender!string;
		textOut.append("row,from,symbol,to");
		foreach ( size_t rowId, Transition transition; transitionTable )
		{
			import std.conv;
			auto maybeFrom = stateSets.get(transition.from);
			auto maybeTo   = stateSets.get(transition.to);

			string from;
			if ( maybeFrom.exists )
				from = maybeFrom.payload.to!string();
			else
				from = "Invalid state set: "~transition.from.to!string();

			string to;
			if ( maybeTo.exists )
				to = maybeTo.payload.to!string();
			else
				to = "Invalid state set: "~transition.to.to!string();

			textOut.append(
				rowId.to!string ~ ","~
				esc(from) ~","~
				esc(transition.symbol.to!string) ~","~
				esc(to));
		}

		return textOut.data;
	}

	void transition(StateNumber from, StateNumber to, SymbolT on)
	{

		StateSetId fromRow = stateSet.ensureExists(from);
		StateSetId toRow   = stateSet.ensureExists(to);

		transitionTableOptimized = false;

		Transition t;
		t.from = fromRow;
		t.to   = toRow;
		t.on   = on;

		transitionTable ~= t;
	}

	void optimizeTables()
	{
		if ( areTablesOptimized() )
			return;

		// Note that the order of operations is important:
		// The transition table algorithm will benefit from faster access
		// times if the state set table is already optimized.
		stateSets.optimize();
		optimizeTransitionTable();
	}

	void sortTransitionsByFromSet()
	{
		auto cmpSets = StateSetIdComparer(stateSet);

		int cmpTransitionsByFromSet(Transition a, Transition b)
		{
			// Primarily, and most importantly, we are comparing by from sets,
			// as identified by their numbered (original) set tuple.
			// This causes transitions from the same state to group together,
			// which simplifies analysis of that transition set.
			int fromCmp = cmpSets.compare(a.from, b.from);
			if ( fromCmp != 0 )
				return fromCmp;

			// At this point, the sets are somehow numerically equal.
			// We'll need to compare based on other members.
			// TODO: What if T doesn't have well-defined comparison semantics? Is that OK?
			if ( a.on < b.on )
				return -1;
			else
			if ( a.on > b.on )
				return 1;

			// Last sorting level is the 'to' state.
			// It is a good idea to ensure complete sorting, as this makes
			// duplicates easy to detect (and debugging output easier to read).
			return cmpSets.compare(a.to, b.to);
		}

		transitionTable.sort!( &cmpTransitionsByFromSet );
	}

	void optimizeTransitionTable()
	{
		sortTransitionsByFromSet();
		transitionTableOptimized = true;
	}
}

struct StateSetTable
{
private:
	size_t                    nextId = 0;

	StateSetMember[]          rows;
	size_t[][StateSetId]      indexOnSetId; /// Maps set IDs to row IDs.
	size_t[][StateNumber]     indexOnStateNumber; /// Maps state numbers to lists of rows.

	bool                      optimized_ = false;

public:

	@property bool isOptimized() const { return optimized_; }

	Maybe!(StateSet) get(StateSetId id)
	{
		StateSetMember[] buffer = null;
		return get(id, buffer);
	}

	Maybe!(StateSet) get(StateSetId id, ref StateSetMember[] buffer)
	{
		LazyStateSet lazySet = anticipateGet(id);
		return Maybe!(StateSet)(lazySet.get(buffer));
	}


	LazyStateSet anticipateGet(StateSetId id)
	{
		size_t[]* rowIdsPtr = id in indexOnSetId;
		if ( rowIdsPtr is null )
			return LazyStateSet.nothing(&this, id);

		size_t[] rowIds = *rowIdsPtr;
		return LazyStateSet(&this, id, rowIds);
	}

	private Maybe!(StateSet) get(LazyStateSet s, ref StateSetMember[] buffer)
	{
		if ( !s.exists )
			return Maybe!(StateSet).nothing();

		if ( s.size == 0 )
			return Maybe!(StateSet)(StateSet(s.id));

		if ( optimized_ )
			return optimizedGet(s, buffer); // O(1); no allocations; icache friendly
		else
			return pessimizedGet(s, buffer); // O(k*log(k)); allocates; icache be ups da river

		assert(0);
	}

	private Maybe!(StateSet) optimizedGet(LazyStateSet s, ref StateSetMember[] buffer)
	{
		assert(this.isOptimized);

		size_t[] rowIds = s.rowIds;

		// Everything is sorted, so we can assume that the StateSetMembers
		// within the table are contiguous if they have the same
		// StateSetId. This allows us to simply return an array slice,
		// which is a fast O(1) operation.
		size_t lo = rowIds[0];
		size_t hi = lo + rowIds.length;
		assert(hi == rowIds[$-1]+1);
		return Maybe!(StateSet)(StateSet(s.id, this.rows[lo .. hi]));
	}

	private Maybe!(StateSet) pessimizedGet(LazyStateSet s, ref StateSetMember[] buffer)
	{
		// If we can't assume sortedness, then we can't take a slice of
		// the table like above. We will have to visit every element
		// of the rowIds array, and every corresponding element of the
		// table. This is, of course, O(k), where k is the number
		// of states in the given state set. Ideally that is small, but
		// the theory of automata teaches us that this isn't always the
		// case. But it gets worse...
		// The result of naive iteration might not be sorted, and we need
		// them to be sorted (and deduped) to allow big-picture sorting and
		// lookup to work efficiently. (Because {1,2,3} is supposed to be
		// the same state-set as {3,1,2} and {1,2,2,3}).
		// So we'll have to sort it ourselves, if that's the case.
		// That makes this O(k*log(k)), potentially, where k is the
		// number of numbered states in the set.

		// But first, a bit of memory allocation.
		size_t[] rowIds = s.rowIds;

		StateSetMember[] result;
		if ( buffer !is null )
		{
			if ( buffer.length >= rowIds.length )
				result = buffer[0 .. rowIds.length];
			else
			{
				// Attempt to reallocate in-place.
				result = buffer[0..$];
				result.length = rowIds.length;
			}
		}
		else
			result = new StateSetMember[rowIds.length];

		// In most cases, our result set will probably be sorted and fine.
		// But there's a chance it isn't.
		// So we'll proceed as if it's sorted, but be on the lookout
		// for inversions and dupes. (If it's sorted, then this WILL
		// catch dupes.)
		bool sorted = true;
		result[0] = this.rows[rowIds[0]];
		for( size_t i = 1; i < rowIds.length && sorted; i++ )
		{
			result[i] = this.rows[rowIds[i]];
			if ( result[i-1].number >= result[i].number )
				sorted = false;
		}

		if ( sorted ) // Also means we're done.
			return Maybe!(StateSet)(StateSet(s.id, result));

		// If there were any problems encountered in the above walk, then
		// we stopped immediately and now need to do some sorting and
		// deduping before we proceed.

		// Note that we can't touch the this.rows table, and thus
		// can't sort THAT. That would be better, but is too big
		// of an operation for a humble lookup.

		// Sort all entries by rearranging row ids.
		import std.algorithm.sorting;

		bool cmpRowIds(size_t rowIdA, size_t rowIdB)
		{
			StateNumber na = this.rows[rowIdA].number;
			StateNumber nb = this.rows[rowIdB].number;
			return na < nb;
		}

		rowIds.sort!(cmpRowIds);

		// Deduplicate entries by removing their row ids.
		StateNumber prev = this.rows[rowIds[0]].number;
		StateNumber next;
		size_t srcIndex = 1;
		size_t dstIndex = 1;
		while ( srcIndex < rowIds.length )
		{
			size_t nextRowId = rowIds[srcIndex];
			srcIndex++;

			// Compare each entry's number against the subsequent
			// entry's number. If they're equal, it's a duplicate.
			next = this.rows[nextRowId].number;
			if ( prev == next )
				continue; // Discard duplicates.

			// This is the part that slides the elements leftwards
			// to fill the gaps left by the removed duplicates.
			// If there are no duplicates, this effectively does nothing.
			rowIds[dstIndex] = nextRowId;
			dstIndex++;

			// Reuse the already-dereferenced entry in the next
			// iteration.
			prev = next;
		}

		// Shorten the array if duplicates were removed.
		rowIds = rowIds[0..dstIndex];

		// Store the result back into the index's entry, so that we
		// don't have to do this again. (This may reduce net
		// algorithmic complexity.)
		*(s.rowIdsPtr) = rowIds;

		// Sorting/dedupe is DONE. Now we can blit our result-set again,
		// but without any interruptions this time.
		for( size_t i = 0; i < rowIds.length; i++ )
			result[i] = this.rows[rowIds[i]];

		// Now the whole lookup is done.
		return Maybe!(StateSet)(StateSet(s.id, result));
	}


	/// Ensures that a state set exists whose only member is the given
	/// StateNumber.
	/// While this is not sufficient for building sets in general, it is
	/// very useful for the construction of initial (unoptimized) automata,
	/// e.g. NFAs.
	/// Returns the StateSetId of the set whose only member is StateNumber.
	StateSetId ensureExists(StateNumber stateNumber)
	{
		// First, check to see if it already exists.
		// If it does, then this is a read-only path and does not disturb
		// any data structure optimizations.
		// (We will still have to check explicitly if optimizations are
		// available, because we don't know initially: it might be, it might not.)
		StateSetId  setId;
		size_t[]* rowIdsPtr = stateNumber in indexOnStateNumber;
		if ( rowIdsPtr !is null
		&&   attemptIdGet(stateNumber, *rowIdsPtr, setId) )
			return setId;

		// If we get here, then it doesn't exist, or has some weird
		// condition like a belonging to a (currently) 0-length state set.
		this.optimized_ = false;

		size_t rowId = rows.length;
		StateSetMember s;
		s.id     = nextId;
		s.number = stateNumber;
		rows ~= s;

		nextId++;

		ensureRowIdExistsInIndex(indexOnSetId, s.id, rowId);
		ensureRowIdExistsInIndex(indexOnStateNumber, s.number, rowId);
		return s.id;
	}

	// Attempt to retrieve the set-id for the set that specifically has one
	// numbered state in it: the state with number 'n'.
	// If successful, returns true.
	// This may fail if such a state does not exist. If that happens, this
	// method shall return false.
	private bool attemptIdGet(StateNumber n, size_t[] rowIds, out StateSetId setId) const
	{
		// A numbered state can appear in any number of state sets, so this
		// logic can't be entirely trivialized.
		// It is important that the state set have a length of 1 and only
		// include the mentioned state number 'n', otherwise we are looking at
		// a different state set that wasn't requested by the caller.
		foreach( rowId; rowIds )
		{
			assert(0 <= rowId);
			assert(rowId < this.rows.length);
			StateSetMember s = this.rows[rowId];

			if ( optimized_ )
			{
				// Assuming sortedness allows us to know very quickly
				// if there are any other numbered (original) states in
				// in this state set.
				if ( rowId > 0 && s.id == this.rows[rowId-1].id )
				{
					// The preceding numbered state is in the same state-set
					// as the one currently selected by rowId. This state-set
					// has more than one number in it, and is thus not the
					// one we are looking for.
					continue;
				}

				if ( rowId+1 < this.rows.length
				&&   s.id == rows[rowId+1].id )
				{
					// The ensuing numbered state is in the same state-set
					// as the one currently selected by rowId. This state-set
					// has more than one number in it, and is thus not the
					// one we are looking for.
					continue;
				}

				// Found it! This is the one, and thus proves that the
				// table has a state-set exclusively for this one state
				// number.
				setId = s.id;
				return true;
			}
			else
			{
				// We can't assume sortedness, so we have to do this the
				// long way and try to retrieve other entries from the
				// same state-set by using associative-array lookups.
				// This is analogous to what happens in the 'get' method,
				// except that it can be MUCH simpler, as it may terminate
				// after finding a second state in the set (or even earlier,
				// if there's only one), and does not need to worry about
				// sortedness (but it does need to worry about the
				// potential for duplicates, which is an unfortunate
				// consequence of non-sortedness).
				assert(s.id in indexOnSetId); // Obviously there is at least one set with this id. (Still verify.)
				const(size_t[]) setSelectRowIds = indexOnSetId[s.id];

				// Now that we've paid for that lookup, we can return
				// immediately in cases where the state-set size is
				// definitely one, and thus satisfies the exclusivity
				// condition of this method.
				if ( setSelectRowIds.length == 1 )
				{
					setId = s.id;
					return true;
				}

				// This set has other numbered states in it.
				// We might still have found the set we want, but only
				// if it's just full of a bunch of duplicate numbered
				// states. That probably isn't going to happen, but
				// we have to handle it for this method to be correct
				// and not cause surprises.
				bool unique = true;
				foreach( setSelectRowId; setSelectRowIds ) {
					if ( s.number != this.rows[setSelectRowId].number ) {
						unique = false;
						break;
					}
				}
				if ( !unique )
					continue; // Confirmed other-numbered state in set. Keep looking.

				// If we got here, then we finally found a state-set that
				// only has this one numbered state in it.
				setId = s.id;
				return true;
			}
		}
		// It is possible that the above foreach loop will fail to find
		// any matching state-sets. That can happen. At this point, we
		// should return false to tell the caller it doesn't exist.
		return false;
	}

	private static int compareRows(StateSetMember a, StateSetMember b)
	{
		if ( a.id < b.id )
			return -1;
		else
		if ( a.id > b.id )
			return 1;
		else
		{
			if ( a.number < b.number )
				return -1;
			else
			if ( a.number > b.number )
				return 1;
			else
				return 0;
		}
	}

	void optimize()
	{
		import std.algorithm.sorting;

		this.rows.sort!((a,b) => compareRows(a,b) < 0);

		// Populate indexOnSetId

		// This will be the easier one, since we can take advantage of
		// the table's sortedness.
		// We will not have to do any AA lookups, just one AA store /per set/.
		// Also, the size_t[] arrays stored in the AA entries will come out
		// sorted for free (no extra steps required).
		indexOnSetId.clear;
		size_t rowId = 0;
		while (rowId < rows.length)
		{
			StateSetMember s = rows[rowId];
			StateSetId refId = s.id;
			size_t[] rowIds = new size_t[0];
			rowIds ~= rowId;
			rowId++;

			while (rowId < rows.length)
			{
				StateSetMember current = rows[rowId];
				StateSetId currentId = current.id;
				if ( currentId != refId )
					break;
				rowIds ~= rowId;
				rowId++;
			}

			indexOnSetId[refId] = rowIds;
		}

		// Populate indexOnStateNumber

		// This might run slower than the above, as it requires an AA lookup
		// and for every single StateSetMember (that is, every state<->set
		// relationship) in the table.
		indexOnStateNumber.clear;
		foreach( size_t i, StateSetMember s; this.rows )
			ensureRowIdExistsInIndex(indexOnStateNumber, s.number, i);

		// If we want the entries in indexOnStateNumber to be sorted,
		// we will have to do that in a second pass, now that we know how
		// many (and which) rows are referenced in each entry.
		foreach( pair; indexOnStateNumber.byKeyValue() )
			pair.value.sort;

		// Optimize the indices themselves.
		indexOnSetId.rehash;
		indexOnStateNumber.rehash;

		// Flag for fast paths wherever it might matter.
		optimized_ = true;
	}

}

/// Offers efficient repeated comparisons of state sets by set ID.
///
/// This struct is large and should not be passed by value. It is designed this
/// way to allow its initial working memory to be stack allocated.
private struct StateSetIdComparer
{
private:
	StateSetTable  table_;

	StateSetMember[16] buffer1Space;
	StateSetMember[16] buffer2Space;
	StateSetMember[] buffer1;
	StateSetMember[] buffer2;

public:

	/// The table that StateSet objects are retrieved from when doing
	/// comparisons.
	@property StateSetTable table() { return table_; }

	/// Copy-construction is disabled, if only to make unfortunate accidental
	/// pessimizations less likely.
	@disable this(ref return scope inout(typeof(this)) src) inout;

	///
	this(StateSetTable table)
	{
		this.table_ = table;
		this.buffer1 = buffer1Space[0..$];
		this.buffer2 = buffer2Space[0..$];
	}

	/// Compares the state sets referenced by the given state-set IDs.
	int compareSets(StateSetId a, StateSetId b)
	{
		// Evaluate state-set retrieval in a delayed fashion.
		// This allows us to do a buffering optimization (below) by knowing
		// the sizes of the sets before we execute the retrieval.
		LazyStateSet  saGetter = table_.anticipateGet(a);
		LazyStateSet  sbGetter = table_.anticipateGet(b);

		if ( !saGetter.exists && !sbGetter.exists )
			return 0; // tie
		else
		if ( !saGetter.exists ) // sa < sb
			return -1;
		else
		if ( !sbGetter.exists ) // sa > sb
			return 1;

		// Rig it so that we always put the larger result in buffer1.
		// This will help buffer-reuse. For example, if an automata has
		// many small state-sets and just one really huge one, there'd
		// be a decent chance that the huge one would end up in both
		// the 'a' and 'b' arguments at different times. The naive approach
		// would have both buffers grow to that big size. But by right-sizing
		// these things, the argument order can't influence memory use, and
		// that scenario would only cause buffer1 to grow to the huge size.
		StateSet sa;
		StateSet sb;

		if ( saGetter.size > sbGetter.size )
		{
			sa = saGetter.get(buffer1);
			sb = sbGetter.get(buffer2);
		}
		else
		{
			sa = saGetter.get(buffer2);
			sb = sbGetter.get(buffer1);
		}

		// At this point we now have two valid state sets
		// that can be properly compared.
		// Assumption: the StateSetMembers in the two state sets are sorted
		// by their .number field and there are no duplicate numbers.
		// These properties of sortedness and uniqueness are guaranteed by the
		// .get methods of StateSetTable and LazyStateSet.
		import std.algorithm.comparison : min;

		if ( sa.length == 0 && sb.length == 0 )
			return 0; // tie
		else
		if ( sa.length == 0 ) // sa < sb
			return -1;
		else
		if ( sb.length == 0 ) // sa > sb
			return 1;
		else
		{
			// Sort by left-most element (as if all other numbered states are fractional elements of the overall number).
			// This will be the most humane to inspect, if that ever needs to happen.
			size_t len = min(sa.length, sb.length);
			for ( size_t i = 0; i < len; i++ )
			{
				StateNumber na = sa[i].number;
				StateNumber nb = sb[i].number;

				if ( na < nb )
					return -1;
				else
				if ( na > na )
					return 1;
			}
		}

		// All numbers are equal, though only up to the shortest
		// of the two sets. If there's a length difference, we'll
		// use that as a tie-breaker.
		if ( sa.length < sb.length )
			return -1;
		else
		if ( sa.length > sb.length )
			return 1;

		// The two state-sets have exactly the same contents, and are thus
		// effectively the same state set. Return indication of equality.
		return 0;
	}

}

/// This struct exists to provide a convenient way to learn how large
/// the 'buffer' array argument to the 'get' method will need to be,
/// and to do so without redundant lookups or unnecessary allocations.
struct LazyStateSet
{
private:
	StateSetTable* owner;
	StateSetId     id_;
	size_t[]*      rowIdsPtr;

	static typeof(this) nothing(StateSetTable* owner, StateSetId id)
	{
		typeof(this) result;
		result.owner     = owner;
		result.id_       = id;
		result.rowIdsPtr = null;
		return result;
	}

	this(StateSetTable* owner, StateSetId id, size_t[] rowIds)
	{
		typeof(this) result;
		result.owner     = owner;
		result.id_       = id;
		result.rowIdsPtr = null;
	}

public:
	/// Returns true if the StateSet exists in the StateSetTable, or
	/// false if it does not.
	@property bool exists() const {
		return (rowIdsPtr !is null);
	}

	/// Returns the number of numbered (original) states in this state set.
	/// This operation does not require any allocations.
	@property size_t size() const {
		if ( exists )
			return rowIds.length;
		else
			return 0;
	}

	/// Returns the StateSetId associated with this state set.
	@property StateSetId id() const {
		return id_;
	}

	/// Returns a list of row identifiers that can be used to retrieve
	/// StateSetMember entries from the StateSetTable.
	/// This must never be called when .exists is false.
	@property inout(size_t)[] rowIds() inout {
		assert(exists);
		return *rowIdsPtr;
	}

	/// This will do the same thing as StateSetTable.get(...), but it
	/// does not need to do initial lookups, because those were already
	/// done to retrieve the LazyStateSet object, which in turn stores
	/// those intermediate results.
	StateSet get(ref StateSetMember[] buffer)
	{
		assert(exists);
		Maybe!StateSet almostResult = owner.get(this, buffer);
		assert(almostResult.exists);
		return almostResult.payload;
	}
}

private size_t[] ensureRowIdExistsInIndex
	(K, T : size_t[][K])
	(ref T index, K key, size_t rowId)
{
	size_t[] rowIds;

	// Concatenate onto existing entries whenever they are available.
	size_t[]* rowIdsPtr = key in index;
	if ( rowIdsPtr !is null )
		rowIds = *rowIdsPtr;

	// Record the row that the state (or whatever) with the given key appears in.
	// We don't sort or dedupe the rowIds, and instead put that computational
	// complexity off until later. This should provide better optimization
	// opportunities, but it does mean that we can't assume those handy
	// properties about this index entry after running this method.
	rowIds ~= rowId;

	// Reuse the pointer if we have it.
	// This means we only need to do the AA store operation once per
	// set: when it is first encountered.
	if ( rowIdsPtr !is null )
		*rowIdsPtr = rowIds;
	else
		index[key] = rowIds;

	return rowIds;
}


