

//interface FiniteStateMachineVisualizer(T)

enum TermColor
{
	none       = 1,
	emphasis   = 2, // Output/Terminal supports attributes like Bold and Reverse Video
	// Skipping 3; there might be something intermediate here.
	colors16   = 4, // 16-color terminal escape code support
	colors256  = 5, // 8-bit (256-color) terminal escape code support, ex: xterm-256color and Linux terminal types.
	colorsTrue = 6, // 24-bit true-color is supported (TODO: which escape codes?)
}

class AsciiVisualizer(T)
{
private:
	Tabulamaton!(T)*  fsm_;
	bool delegate(dchar[] chunk) onDraw_;
	TermColor  colorLevel_;
	Phase      phase_;

	enum Phase
	{
		graphConstruction,
		gridSizing,
		layout,
		rendering
	}

	string phaseToString(Phase p)
	{
		final switch(p)
		{
			case Phase.graphConstruction: return "Graph Construction";
			case Phase.gridSizing:        return "Grid Sizing";
			case Phase.layout:            return "Calculating Layout";
			case Phase.rendering:         return "Rendering";
		}
	}

public:
	/// This must be called before the .processOneWorkUnit method can be
	/// called.
	///
	/// The 'onDraw' method will be called whenever there is text to be
	/// displayed or stored. This will happen after calls to .processOneWorkUnit,
	/// though the initial work may not call 'onDraw', since there will be
	/// a decent amount of compute time spent laying out the graph before
	/// anything can actually be drawn.
	///
	/// 'onDraw' should return true normally, but it can return false if the
	/// whole visualization is to be aborted. In that case, onDraw will not
	/// be called again until the next call to .processOneWorkUnit(), at
	/// which point it will retry the aborted draw operation and proceed with
	/// any others that might fit into the resumed work unit.
	void startDraw(
		Tabulamaton!(T)* fsm,
		bool delegate(dchar[] chunk, size_t x, size_t y, size_t chunkWidth) onDraw,
		TermColor  colorLevel = TermColor.none
	)
	{
		assert(fsm !is null);
		assert(onDraw !is null);
		this.fsm_        = fsm;
		this.onDraw_     = onDraw;
		this.colorLevel_ = colorLevel;
	}

	/// Does some layout or drawing work, then returns. This will attempt to
	/// avoid blocking for long periods of time, so that the caller's thread
	/// may remain responsive.
	///
	/// If the input state machine is small, or responsiveness (ex: progress
	/// reporting) is not required, then this can just be called repeatedly
	/// until it returns false.
	///
	/// This returns false once the visualization has been completely written
	/// into the 'onDraw' delegate assigned during the call to 'startDraw'.
	///
	/// If the 'onDraw' delegate returns false, this will still return true,
	/// as there is still potentially work to be done once the caller is able
	/// to return true from 'onDraw' again.
	bool processOneWorkUnit()
	{
		final switch(this.phase_)
		{
			case Phase.graphConstruction: doGraphConstruction(); return true;
			case Phase.gridSizing:        doGridSizing(); return true;
			case Phase.layout:            doLayout(); return true;
			case Phase.rendering:         return doRendering();
		}
	}

	/// Provides an abstract indicator of progress.
	///
	/// Note that the 'totalSteps' number could change due to ealier calculations
	/// learning that the total work will be easier or harder. If these numbers
	/// are presented as a percentage, then it could make progress seem to
	/// regress. That might be acceptable, but if it's not, then it might be
	/// more appropriate to simply display the fraction and a spinner or other
	/// animation, with the animation updating every time processOneWorkUnit()
	/// returns. Although unlikely, the Progress value returned could remain
	/// the same between work units, so animating independent of this would
	/// be a good idea. Once the 'totalIsFirmed' member becomes true, it will
	/// no longer change, and it becomes possible to display the progress
	/// in a manner such as a percentage or bar without any perceived
	/// regression of progress.
	struct Progress
	{
		size_t stepsDone;
		size_t totalSteps;
		string currentPhase;
		bool   totalIsFirmed;
	}

	/// ditto
	void getProgress(ref out Progress stats)
	{
		TODO write this.
	}

	/// This method applies a clipping rectangle before any text is sent
	/// to the 'onDraw' callback. This potentially allows for optimizations
	/// where content is simply not calculated for nodes outside of the
	/// clipping rectangle, along with the possibility that calls to 'onDraw'
	/// might be avoided completely. This is unlikely to save on computation
	/// time in the earlier stages that don't involve rendering.
	///
	/// A note about the coordinate space used by this method:
	///
	/// The coordinate space is the typical right-handed space used in mathematics
	/// and graphics, not the row-column layout of displays. It does have a
	/// one-to-one relationship with row-column coordinates, so it is easily
	/// converted according to this relationship:
	///
	/// row := (height-1) - y
	/// col := x
	///
	/// This assumes that (col,row) are indexed in a 0-based fashion.
	///
	/// The output will start at coordinate (0,height-1) and proceed left-to-right,
	/// skipping spaces that trail line-endings, then top-to-bottom, until
	/// it reaches (width-1,0), though possibly with a lower x-coordinate due
	/// to the skipping of trailing spaces.
	void setClippingRect(size_t x1, size_t y1,  size_t x2, size_t y2)
	{
	}

private:

	enum Direction
	{
		from,
		to
	}

	struct TransitionPossibility
	{
		T[]   symbols;

		bool  isRange() { return symbols.length > 1; }
	}

	struct Edge
	{
		Node*                    other;
		TransitionPossibility[]  transitionSymbols; // Effectively the label for the edge.
		Direction                direction;
	}

	struct Node
	{
		StateNumber[]  stateSet; // Effectively the label for the node itself.
		Edge[]         allEdges;
		Edge[]         inEdges;
		Edge[]         outEdges;
	}

	void doGraphConstruction()
	{
		fsm.optimizeTables();
	}
}


