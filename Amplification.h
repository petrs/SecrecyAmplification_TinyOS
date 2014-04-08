#ifndef AMPLIFICATION_H
#define AMPLIFICATION_H

enum {
	AM_MEASURE = 90,
	AM_DISTANCES = 91,
	AM_SECAMPLIF = 92,
	AM_VERIFY = 93,
	AM_VERIFY_RESP = 94,
	MAX_NEIGHBORS = 50, // the size of tables for neighbors
	MAX_COMMUNICATION_NEIGHBORS = 5, // the size of tables for neighbors
	AMPLIF_VALUE_LENGTH = 1,		// TODO: Should be 8
	TIMER_MEASURE_PACKET_DELAY = 200,		// delay between separate measuring packets
	TIMER_MEASURE_PACKET_PERIOD_LENGTH = 20000,	// length of period for measuring RSSI
	TIMER_VERIFY_DELAY = 5000,	// length of period before verification of secrecy amplification is performed
	TIMER_SEND_RSSI_DELAY = 40000, // all nodes should have finished sending measure packets
	MEASURE_PACKETS_MIN_REQUIRED = 10,

	STATE_RSSI_MEASURE = 1,             // first phase for RSSI measurement
	STATE_COMPUTE_RSSI = 2,             // second phase for RSSI computation
	STATE_RSSI_COMPUTED = 3,            
	STATE_SEND_MEASURED_RSSI = 4,
	STATE_COMPUTE_RELATIVE_DIST = 5,
	STATE_SECRECY_AMPLIF = 6,           // third phase for secrecy amplification
	STATE_VERIFY_SECRECY_AMPLIF = 7,
	STATE_OPERATIONAL = 8,              // last phase - operational

	SA_STATE_INIT = 1,
	SA_STATE_READYFORHYBRID1 = 2,
	SA_STATE_READYFORHYBRID2 = 3,
	SA_STATE_VERIFY_RDY = 4,
	SA_STATE_VERIFY = 5,
	SA_STATE_VERIFY_WAITING = 6,
	SA_STATE_FINISHED = 7,
};

typedef struct neighbors {
	uint16_t nodeId; // id of the neighbor
	int16_t avgRSSI; // rssi of the signal received from neighbor (averaging)
	int16_t avgRSSICount; // number of measure packets received so far
	uint8_t secAmplifState; // current state of secrecy amplification for this node
	int16_t forwarderHybrid1; // forwarder for hybrid 1 proctol
	int16_t forwarderHybrid2; // forwarder for hybrid 2 proctol
	uint16_t amplifValueHybridMaster1[AMPLIF_VALUE_LENGTH];	// sub-key send during hybrid 1 protocol where the TOS_NODE_ID is master
	uint16_t amplifValueHybridMaster2[AMPLIF_VALUE_LENGTH];	// sub-key send during hybrid 2 protocol where the TOS_NODE_ID is master
	uint16_t amplifValueHybridSlave1[AMPLIF_VALUE_LENGTH];	  // sub-key send during hybrid 1 protocol where the neighbor is master
	uint16_t amplifValueHybridSlave2[AMPLIF_VALUE_LENGTH];	  // sub-key send during hybrid 2 protocol where the neighbor is master 
	uint16_t sharedKey[AMPLIF_VALUE_LENGTH];	                // current shared key
} neighbors_t;

typedef struct nodeRSSI {
	uint16_t nodeId; // id of the neighbor
	int16_t rssi; 	 // rssi of the signal received from neighbor
} nodeRSSI_t;



// Message used to measure RSSI
typedef struct measureMsg {
	uint16_t senderId;
} measureMsg_t;

// Message containing list of measured RSSI values from neighbours of given node
typedef struct distancesMsg {
	uint16_t senderId;
	nodeRSSI_t measuredRSSI[MAX_COMMUNICATION_NEIGHBORS];
} distancesMsg_t;

// Message used to send amplification value
typedef struct secamplifMsg {
	uint16_t masterId;
	uint16_t slaveId;
	uint16_t forwarderId;
	uint16_t amplifValue[AMPLIF_VALUE_LENGTH];
	uint8_t protocolIndex;	// id of protocol now 1 and 2 is used	
} secamplifMsg_t;


// Message asking if all amplification values were transmitted
typedef struct verifyMsg {
	uint16_t masterId;
	uint16_t slaveId;
	uint16_t requiredValuesMask;
} verifyMsg_t;

// Message confirming received amplification values 
typedef struct verifyResponseMsg {
	uint16_t masterId;
	uint16_t slaveId;
	uint16_t calculatedValuesMask;
} verifyResponseMsg_t;


#endif /* AMPLIFICATION_H */
