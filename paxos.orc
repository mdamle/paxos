{-

Simulation of Basic Paxos Consensus Protocol

Authors: Hemanth Kumar Mantri (HM7787), Makarand Damle (MSD872)
         mantri@cs.utexas.edu, mdamle@cs.utexas.edu
         Department of Computer Science
         The University of Texas at Austin

References: 1. Paxos Made Simple, Leslie Lamport
         	2. ORC Reference Guide: http://orc.csres.utexas.edu/
            3. Professor Seif Haridi's Video Lectures on YouTube
            4. IIT Madras Video Lectures on YouTube
            5. http://the-paper-trail.org

Tags: distributed-consensus paxos
-}

{- type of messages -}
val PREP = "prepare" 		-- prepare message, (Proposer --> Acceptor)
val ACPT = "accept" 		-- accept message (Proposer --> Acceptor)

val PRM = "promise" 		-- promise message (Acceptor --> Proposer)
val NACK = "negativeack" 	-- reject message (Acceptor --> Proposer)
val ACPTD = "accepted" 		-- accepted message (Acceptor --> Proposer)

val DEC = "decide" 			-- decision message (Proposer --> Client)
val CLNTREQ = "clientreq" 	-- client request (Client --> Proposer)

val HBT = "heartbeat" 		-- hearbeat message (Every Acceptor/Proposer --> Every Other Acceptor/Proposer)
val TMOUT = "timedout" 		-- timeout message (Placeholder when Timeout occurs)
val REPN = "replication" 	-- replication message (Acceptor --> Listener)

{- roles of Nodes -}
val PROP = "proposer" 		-- proposes a value requested by client
val LIST = "listener" 		-- learn from acceptors, when they accept
val ACCP = "acceptor" 		-- reject a proposal or accept and send the accepted value to listeners
val CLNT = "client" 		-- suggests a value to the proposer

{- state of Proposer -}
val PHASE1 = "phase1" 		-- in phase 1
val PHASE2 = "phase2" 		-- in phase 2
val DCD = "decided" 		-- final state is decided
val RJT = "rejected" 		-- rejected in phase1 or phase 2
val INIT = "init" 			-- initial stage
  
{- Global Utility Methods -}

def printChIds([]) = Println("")
def printChIds(ch:chs) = Print(ch.getId()) >> printChIds(chs)

-- methods needed to filter desired channels/processes from the list
-- of all channels and processes
val globalCurrent = Ref(-1)

def checkDst(src,dst) =
if (src = dst)
then false
else (Ift(dst = globalCurrent?) >> true ) ; false
     
def checkSrc(src,dst) =
if (src = dst)
then false
else (Ift(src = globalCurrent?) >> true ) ; false

def testChListener(ch) =
ch.getRole()>role> (if (role? = LIST) then true else false)

def testChIn(ch) =
ch.getId() >(src,dst)> checkDst(src,dst)

def testChOut1(ch) =
ch.getId() >(src,dst)> checkSrc(src,dst)

def testZeroOut(ch) =
ch.getId() >(src, dst)> (if (src = 0) then true else false)

def testChOut2(ch) =
ch.getRole()>role> (if (role? = LIST) then false
else (ch.getId() >(src, dst)> checkSrc(src,dst)))
   
def testListener(p) = p.getRole() >role> (if (role? = LIST) then true else false)
def testAcceptor(p) = p.getRole() >role> (if (role? = ACCP) then true else false)
def testProposer(p) = p.getRole() >role> (if (role? = PROP) then true else false)
def testClient(p) = p.getRole() >role> (if (role? = CLNT) then true else false)


{- Encapsulates Message Info -}
def class message(mtype, seq, data) =
val msgType = mtype
val seqNum = seq -- current seqNum for PREP/ACPT, current/lastmaximum for PRM
val value = data

def getVal() = value
def getType() = msgType
def getSeq() = seqNum
stop

{- let the put fail with a probability 'p/100' to mimic a faultyChannel -}
def class faultyChannel(fail, id) =
  val chId = id
  val ch = Channel()
  val role = Ref(ACCP)
  val p = Ref(fail)
  
  def getFail() = p?
  def get() = ch.get()
  def put(x) =
     if ((Random(99) + 1) :> p?)
       then ch.put(x)
     else signal

  def getId() = chId
  def getRole() = role
  def setRole(r) = role := r
  def setFail(f) = p := f

  def printInfo() = Println("Channel:" +id+ "Role: "+role?)
stop

{-
	encapsulates proposer, acceptor and listener nodes
	can be instantiated to work exclusively as one of proposer, acceptor or listener or 
	any combination of them.
-}
def class process(id, tOut, numNodes, role, in:ins, out:outs, lisnts) =

{-- Generic Process State -}
val role = Ref(role)
val lock = Semaphore(1)
val pid = id
val maxDelay = 1
val timeout = tOut
-- nodes alive in my perspective
val alive = fillArray(Array(numNodes), lambda(i) = true)
val leader = Ref(0)

{- Proposer State 
	   transitions from 
	   		init-->phase1-->phase2-->accepted OR
	   		init-->phase1-->rejected	  OR
	   		init-->phase1-->phase2-->rejected
-}
val PropHighestSeqNo = Ref(id)
val Proplock = Semaphore(1)
val PropNumPromised = Ref(0)
val PropNumNotPromised = Ref(0)
val PropNumAccepted = Ref(0)
val PropNumRejected = Ref(0)
val PropQuorumSize = Ref(numNodes/2)
val PropState = Ref(INIT)
--val PropQuorumSize = Ref(numNodes - 4)


{- Acceptor State
		No explicit state management for Accpetor. It only has to accpet or reject a proposal
		based on the highest seqquence number it has seen.
-}
val AcpHighestSeqNo = Ref(id)
val Acplock = Semaphore(1)

{- Client State -}
val clntReq = Ref(0)
val clntServed = Ref(0)

{- Listener State -}
val lsnrStore = Ref(0)

{- Generic Process Methods -}

{- given an in-channel, get the corresponding out-channel
  - input: channel corresponding to (2,3)
  - output: channel corresponding to (3,2)
     -}
def getOutch(ch, []) = stop
def getOutch(ch, out:outCh) =
	ch.getId() >(src, dst)>
	out.getId()>(a, b)>
	(if(b = src)
	then out
	else getOutch(ch, outCh))

   -- send a message to all other nodes
def broadcast(msg) =
    map(lambda(ch) = Rwait(Random(maxDelay)) >> ch.put(msg), out:outs) >> signal
    
-- propogate accepted value to the listeners to replicate
def sayListeners(msg) =
	map(lambda(ch) = Rwait(Random(maxDelay)) >> ch.put(msg), lisnts) >> signal
   
def getRole() = role
def setRole(r) = (role := r)
def getId() = pid
def myInChannels() = in:ins
def myOutChannels() = out:outs
def setPropState(s) = PropState := s

{- client Methods -}
{-
def sendClientReq(v) =
Println("Client (Process-"+pid+") requests the Leader (Process-"+getLeader(procList)+") for value:"+v) >>
clntReq := v >> message(CLNTREQ, -1, v) >m> getLeaderCh(out:outs) >ch> ch.put(m)

def recvConsensus(v) =
Println("Client (Process-"+pid+") was served by Leader (Process-"+getLeader(procList)+") with consensus:"+v) >>
clntServed := v
-}
 

{- Proposer Methods -}
def generateNextSeqNo() = PropHighestSeqNo := PropHighestSeqNo? + numNodes

def increment(x) = x := x? +1

{- sends prepare message to all acceptors
   and transitions from init --> phase1
 -}
def sendPrepare() = 
	setPropState(PHASE1) >>
	leader := pid >>
	Println("Process " + id + " in sendPrepare(). Thinks current leader is process " +leader?) >>
	generateNextSeqNo() >> message(PREP, PropHighestSeqNo?, 999) >m> broadcast(m)

{- receives promise message from all accpetors
   If majority (greater than quorum size) of acceptors send an ack
   transiton from phase1-->phase2 and do a send accept.
   If majority of acceptors send a nack transition from phase1-->rejected
   and retry (do  prepare) with a higher sequence number
-}
def receivePromise(m, outch) = 
	-- Check for nack 
	(if (m.getVal() = -1) then
		(increment(PropNumNotPromised) >>
		Println("Process " + id + " received NACK in receivePromise(): total nack received = " + PropNumNotPromised?) >>
		(if (PropNumNotPromised? >= PropQuorumSize?) then
			(setPropState(RJT) >> sendPrepare())
		else signal))
	else
		(increment(PropNumPromised) >> 
		Println("Process " + id + " in receivePromise(): total promise received = " + PropNumPromised?) >>
		moveToAccept()))

def moveToAccept() = 
	if ((PropNumPromised? >= PropQuorumSize?) && (PropState? = PHASE1)) then
		(setPropState(PHASE2) >> sendAccept())
	else
		signal

-- broadcast accept() to all acceptors
def sendAccept() = 
	Println("Process " + id + " in sendAccept()") >>
	message(ACPT, PropHighestSeqNo?, 999) >m> broadcast(m)

{- receives accepted message from all acceptors.
   If majority (greater than quorum size) of acceptors send an ack
   transition from phase2-->accepted.
   If majority of acceptors send a nack transition from phase2-->rejected.
-}
def receiveAccepted(m, outch) = 
	(if (m.getVal() = -1) then
		(increment(PropNumRejected) >>
		Println("Process " + id + " in receiveAccepted(): total nack received = " + PropNumRejected?) >>
		(if (PropNumRejected? >= PropQuorumSize?) then
			setPropState(RJT)
		else signal))
	else
		(increment(PropNumAccepted) >> 
		Println("Process " + id + " in receiveAccepted(): total accepted received = " + PropNumAccepted?) >>
		moveToAccepted()))

def moveToAccepted() = 
	if ((PropNumAccepted? >= PropQuorumSize?) && (PropState? = PHASE2)) then
		(Println("Quorum = " + PropQuorumSize? + " reached Proposal Accepted for process "+pid+"'s proposed value ") >>
		setPropState(DCD))
	else
		signal


{- Acceptor Methods -}

{- receives a prepare message from proposer. Checks if the sequence number received is
   greater than the highest sequence number seen by it. If so, sends accept message.
   Otherwise sends nack message with the highest sequence number it has seen so far.
   
   Note: If the node is a proposer and receives prepare message,
         and if sequence number it received is greater than PropHighestSeqNo, 
         it changes its role to Acceptor. This is not part of the classic paxos algorithm but 
         must be seen as an optimization that helps it acheive consensus faster.
-}
def receivePrepare(m, outch) = 
	Println("Process " + id + " in receivePrepare()") >>
	(if (role? = PROP) then
		doPropReceivePrepare(m, outch)
	else
		doAccpReceivePrepare(m, outch))

def doPropReceivePrepare(m, outch) =
	if ((PropHighestSeqNo? <: m.getSeq())) then
		(setRole(ACCP) >> Println("Changing " +pid+ " from PROP to ACCP" ) >>
		(if (AcpHighestSeqNo? <: m.getSeq()) then 
			sendPromise(m, outch) >> AcpHighestSeqNo := m.getSeq() 
		else 
			sendPromiseNack(m, outch)))
	else
		signal

def doAccpReceivePrepare(m, outch) =
	(if (AcpHighestSeqNo? <: m.getSeq()) then 
		sendPromise(m, outch) >> AcpHighestSeqNo := m.getSeq() 
	else 
		sendPromiseNack(m, outch))

def sendPromise(m, outch) = 
	Println("Process " + id + " in sendPromise()") >>
	outch.getId() > (src, dst) > leader := dst >>
	Println("Process " + id + " thinks current leader is process " + leader?) >>
	message(PRM, m.getSeq(), AcpHighestSeqNo?) >m> outch.put(m)

def sendPromiseNack(m, outch) = 
	Println("Process " + id + " in sendPromiseNack()") >>
	message(PRM, m.getSeq(), -1) >m> outch.put(m)

{-
	Recieves accept message from proposer. Marks phase 2 of the protocol for the given proposer.
	If sequence number it receives is >= the highest sequence number it has seen, it sends accepted message.
	Else it sends a nack.
-}
def receiveAccept(m, outch) = 
	Println("Process " + id + " in receiveAccept()") >>
	(if (m.getSeq() >= AcpHighestSeqNo?) then 
		sendAccepted(m, outch) >> sayListeners(m) >> AcpHighestSeqNo := m.getSeq() 
	else 
		sendAcceptedNack(m, outch))

def sendAccepted(m, outch) = 
	Println("Process " + id + " in sendAccepted()") >>
	message(ACPTD, m.getSeq(), AcpHighestSeqNo?) >m> outch.put(m)

def sendAcceptedNack(m, outch) = 
	Println("Process " + id + " in sendAcceptNack()") >>
	message(ACPTD, m.getSeq(), -1) >m> outch.put(m)

-- Handles proposer input messages
def handlePropInMsg(m, outch) = 
	(if (m.getType() = PRM) then 
		receivePromise(m, outch) 
	else
		(if (m.getType() = ACPTD) then 
			receiveAccepted(m, outch) 
		else 
			signal))

-- Handles acceptor input messages
def handleAcpInMsg(m, outch) = 
	(if (m.getType() = PREP) then 
		receivePrepare(m, outch) 
	else
		(if (m.getType() = ACPT) then 
			receiveAccept(m, outch) 
		else 
			signal))

def recvReplication(m) =
lsnrStore := m.getVal()

{-
	If timeout detected set the node status to false.
	If leader was made false handleLeaderFailure()
-}
def handleTimeout(src, dst) = 
	--Println("Timeout Detected by Process " + dst + " for Process " + src + " leader = " + leader?) >>
	alive(src).write(false) >>
	(if (src = leader?) then 
		handleLeaderFailure() 
	else 
		signal)

{-
	If leader timed out and if the current node is the max alive node,
	change itself to Proposer if not already one and send prepare message.
	If current node is not the max alive node, do nothing.
-}
def handleLeaderFailure() = 
	--Println("Process " + pid + " in handleLeaderFailure() with maxAlive = " + maxAlive(numNodes-1)) >>
	(if (maxAlive(numNodes-1) = pid) then
		(Println("Process " + pid + " in handleLeaderFailure() is " + role? + " and is the maxAlive process. Making itself leader ") >>
		(if (role? = PROP) then 
			(lock.acquire() >> sendPrepare() >> lock.release())
		else 
			(lock.acquire() >> setRole(PROP) >> sendPrepare()) >> lock.release()))
	else 
		signal)

-- finds index of the max alive node
def maxAlive(0) = if (alive(0)? = true) then 0 else signal
def maxAlive(i) = if (alive(i)? = true) then i else maxAlive(i-1)

-- sends periodic heartbeat to all nodes to test their aliveness
def sendHBeat(ch) =
	ch.getId() >(src, dst)> (message(HBT, -1, -1) >m> ch.put(m)) >> Rwait(timeout) >> sendHBeat(ch)

def handleListInMsg(m, outch) = (if (m.getType() = REPN) then recvReplication(m) else signal)

{- 
	handle input message for proposer. Note that proposer doubles up a acceptor in our system.
	Thus it calls both handlePropInMsg() and handleAcpInMsg().
-}
def handleInMsg("proposer", m, outch) =
    lock.acquire() >> handlePropInMsg(m, outch) >> handleAcpInMsg(m, outch) >> lock.release()

-- handle input message for acceptor
def handleInMsg("acceptor", m, outch) =
	lock.acquire() >> handleAcpInMsg(m, outch) >> lock.release()

-- handle input message for listener
def handleInMsg("listener", m, outch) =
    lock.acquire() >> handleListInMsg(m, outch) >> lock.release()

-- calls either timeout or normal input message handler depending on the message received
def processMsg(m, ch) = 
	ch.getId() >(src,dst)>
	(if (m.getType() = TMOUT) then
		handleTimeout(src, dst)
	else 
		handleInMsg(role?, m, getOutch(ch, out:outs)))

{- 
	calls ch.get() and Rwait(timeout) in parallel. Pruns and uses the first publication received.
	used to detect timeouts.
-} 
def handleMsg(ch) = 
	(processMsg(m, ch) <m< (ch.get() | (Rwait(3 * timeout) >> message(TMOUT, -1, -1)))) >> handleMsg(ch)

-- runs infinitely, sending hearbeat messages and polling input channles in parallel
def run() = (map(sendHBeat, out:outs) | map(handleMsg, in:ins))

-- print state of the process
def printInfo() = Println("Process ID: "+pid + " Role: "+ role?)

-- print extended state of the process
def printInfo_extended() =
Println("Process ID: "+pid + " Role: "+ role?) >> Println("In Channels: ") >> printChIds(in:ins) >>
Println("Out Channels: ") >> printChIds(out:outs)>> Println("Listener channels ") >>
printChIds(lisnts)
 
stop


{- Class to encapsulate the whole system state: Processes and Channels.
   All processes are initialized here and the mapping to channels is stored.
   Roles of the processes can be changed later. Failures can be simulated by failing out-channels.
   CAUTION: There should be atleast 3 nodes in the system
            to prevent array bound errors
-}
def class distributedSystem(failProb, timeOut, numNodes, numListeners) =

val lock = Semaphore(1)
val chArray = fillArray(Array(numNodes * numNodes), lambda(slot) = faultyChannel(failProb, (slot/numNodes, slot%numNodes))) -- array of all channels
val procArray = Array(numNodes)
  
-- Initialize all channels in the Distributed System (UNUSED: see above declaration)
def initChannels(i) =
	if (i <: numNodes * numNodes) then 
		chArray(i) := faultyChannel(failProb, (i/numNodes, i%numNodes)) >> initChannels(i+1)
	else 
		signal
  
-- Initialize all nodes in the Distributed System
-- Should be called after initializing channels

-- initialize the listeners/learners
def initListeners(i) =
	if (i <: numListeners) then 
		Println("initing listener-"+i) >>
		globalCurrent.write(i) >>
		filter(testChIn, arrayToList(chArray)) >ins>
		filter(testChOut1, arrayToList(chArray)) >out1>
		filter(testChListener, out1) >lisnts>
		filter(testChOut2, arrayToList(chArray)) >outs>
		procArray(i) := process(i, timeOut, numNodes, LIST, ins, outs, lisnts) >>
		initListeners(i+1)
	else 
		signal

-- initialize acceptors, proposer and client
def initProcs(i) =
	if (i <: numNodes) then 
		Println("initing process-"+i) >>
		globalCurrent.write(i) >>
		filter(testChIn, arrayToList(chArray)) >ins>
		filter(testChOut1, arrayToList(chArray)) >out1>
		filter(testChListener, out1) >lisnts>
		filter(testChOut2, arrayToList(chArray)) >outs>
		(if (i = numListeners) then 
			procArray(i) := process(i, timeOut, numNodes, ACCP, ins, outs, lisnts)
		else
			if (i = numListeners +1) then 
				procArray(i) := process(i, timeOut, numNodes, PROP, ins, outs, lisnts)
			else 
				procArray(i) := process(i, timeOut, numNodes, ACCP, ins, outs, lisnts)) >> initProcs(i+1)
	else 
		signal

-- set the roles of listerner channels to differentiate them from regular channels
def setListen(ch) = ch.setRole(LIST)

def setChRoles(i) =
	if (i <: numListeners) then 
		globalCurrent.write(i) >> 
		filter(testChIn, arrayToList(chArray)) >lisns> map(setListen, lisns) >>
		setChRoles(i+1)
	else 
		signal

   -- Main function to initialize the system.
def init() = 
	setChRoles(0) >> initListeners(0) >> initProcs(numListeners) >>
	Println("Initialzied "+numNodes+" processes.")


-- get the list form of processes and channels
def getProcList() = arrayToList(procArray)
def getChList() = arrayToList(chArray)

-- filter desired nodes from the whole bunch
def getProposers() = filter(testProposer, arrayToList(procArray))
def getClients() = filter(testClient, arrayToList(procArray))
def getListeners() = filter(testListener, arrayToList(procArray))
def getAcceptors() = filter(testAcceptor, arrayToList(procArray))

-- redesignate a chosen node
def setProposer(i) = procArray(i)?.setRole(PROP)
def setAcceptor(i) = procArray(i)?.setRole(ACCP)


-- print the information related to one/all processes
def printProcessInfo(i) = procArray(i)?.printInfo()
def printProcs() =
	upto(numNodes) >i> lock.acquire()>> printProcessInfo(i) >> lock.release()
def printProcesses([]) = signal
def printProcesses(pr:prs) = pr.printInfo() >> printProcesses(prs)

-- print information related to all channels
def printChannels([]) = signal
def printChannels(ch:chs) = ch.printInfo() >> printChannels(chs)


-- methods to simulate failure and recovery of nodes/channels
def setChFail(ch) = ch.setFail(100)
def setChUnfail(ch) = ch.setFail(0)

def failRandomNode() =
Random(numNodes) >i> map(setChFail, procArray(i)?.myOutChannels())
def unfailRandomNode() =
Random(numNodes) >i> map(setChUnfail, procArray(i)?.myOutChannels())

def failNode(i) =
map(setChFail, procArray(i)?.myOutChannels())
def unfailNode(i) =
map(setChUnfail, procArray(i)?.myOutChannels())

stop

------------------------------------------- GOAL Expressions -------------------------------------

val sem = Semaphore(1) 	-- needed for proper printing of processes/channel information
val numListeners = 0 	-- number of Listeners/Learner's in the system. Needed only if you want replication
val numNodes = 8 		-- total number of nodes in the distributed system
val failProb = 0 		-- probability of link/node failure
val timeOut = 1500 		-- timeout(ms) before declaring failure

-- Instantiate a distributed System
val ds = distributedSystem(failProb, timeOut, numNodes, numListeners)

-- Get the list of processes and channels
val procs = ds.getProcList()
val channels = ds.getChList()

-- Extract proposer(s) and Acceptors
val proposers = ds.getProposers()
val acceptors = ds.getAcceptors()

-- function to be run by all processes
def run(p) = p.run()

-- funtion to be run by the initial proposer to trigger the protocol
def start(p) = p.sendPrepare()

def printId(p) = Print("Process: "+p.getId())

-- print the list of acceptors and proposers' information
def printAcceptors() = sem.acquire() >> ds.getAcceptors() >a> ds.printProcesses(a) >> sem.release()
def printProposers() = sem.acquire() >> ds.getProposers() >p> ds.printProcesses(p) >> sem.release()

-- Randomly fail and unfail nodes. Doesn't guarantee convergence. Correctness is guaranteed, not liveness.
def failUnfailRandom() =
Random(4000) >r> Rwait(r) >> ds.failRandomNode() >> Rwait(4000) >> ds.unfailRandomNode() >>
Rwait(4000) >> failUnfailRandom()

Println("============= Starting Classic Paxos Simulation =========") >> ds.init() >>
Println("======== DS Initialized ===========") >>
Println("Proposer(s) are: ") >>
printProposers() >>
Println("Acceptor(s) are: ") >>
printAcceptors() >>

{- Starts the simulation with convergence
  - The simulation runs forever (HeartBeat messages will be sent) and will need to be stopped
    when a proposal gets accepted for last value.
  -
-}

--1.
{- Successful Paxos round simulation in absence of any failures.
   Uses default init configuration, 1 as Proposer, 0 and 2-7 as Acceptors. 
   Concludes with 1 achieving consensus with 7 votes. 
-}
-- (map(start, ds.getProposers()) >> map(run, ds.getProcList()))

--2.
{- Successful Paxos round simulation in presence of 1 Acceptor failure.
   Uses default init configuration, 1 as Proposer, 0 and 2-7 as Acceptors, 
   but forcefully fails Acceptor 0 after waiting for an arbitrary time > 1000 ms. 
   Concludes with 1 achieving consensus with either 6 or 7 votes depending on when node 0 fails. 
-}
--(map(start, ds.getProposers()) >> map(run, ds.getProcList())) | 
--(Random(2000) >r > Rwait(r + 800) >> ds.failNode(0))

--3.
{- Successful Paxos round simulation in presence of leader/proposer failure.
   Uses default init configuration, 1 as Proposer, 0 and 2-7 as Acceptors, but 
   forcefully fails Proposer 1 after some arbitrary time. Depending on when 1 fails,
   the system either makes progress with 1 or elects a new leader, that is the max alive node 
   (node id 7) and 7 takes the protocol to conclusion.
   This condition is hard to achieve and requires multiple (> 10) tries. 
-}
--(map(start, ds.getProposers()) >> map(run, ds.getProcList())) |
--(Random(1000) > r > Rwait(1500 + r) >> ds.failNode(1))

--4.
{- Successful Paxos round simulation in presence of leader/proposer failure and recovery.
   Uses default init configuration, 1 as Proposer, 0 and 2-7 as Acceptors, but 
   forcefully fails Proposer 1 after some time and then recovers it. The system elects a new leader, 
   that is the max alive node (node id 7) and 7 takes the protocol to conclusion. 1 comes back as
   proposer but changes itself silenty to Acceptor if its sees proposal number of 7 > that of itself.
   This condition is hard to achieve and requires multiple (>10) tries.
-}
--(map(start, ds.getProposers()) >> map(run, ds.getProcList())) |
--(Random(1000) > r > Rwait(1500 + r) >> ds.failNode(1) >> Rwait(4500) >> ds.unfailNode(1))

--5.
{- Starts the simulation with/without convergence due to random failures and recoveries
-}
-- (map(start, ds.getProposers()) >> map(run, ds.getProcList())) | failUnfailRandom()

--6.
{- Some other random config with multiple leader elections and obtainment of consensus. 
-}

(map(start, ds.getProposers()) >> map(run, ds.getProcList())) |
(Rwait(6000) >> (ds.failNode(1)) >> Rwait(3000) >> ds.failNode(7))
>> Rwait(8000) >> ds.failNode(6) >> ds.unfailNode(7) >> Rwait(8000) >> ds.failNode(5)
