#define DEBUG_PRINTF
#define INCLUDE_BODY
#include "Amplification.h"
#include "Log.h"
#include "AES.h" 		//AES constants

module AmplificationC {
	uses {
		interface Boot;
		interface Leds;
		interface Timer<TMilli> as TimerMeasurePacket; // Sending measure packets 
		interface Timer<TMilli> as TimerMeasureEnd;    // Finish the measurement
		interface Timer<TMilli> as TimerSendRSSI;      // Sends measured RSSI
		interface Timer<TMilli> as TimerVerify;        // Delays verification message to make delivery possible and reset the protocol in case verification lost
		interface Timer<TMilli> as TimerBootDelay;     // Delays all operations after boot, for connecting serial interfaces
		interface Timer<TMilli> as TimerSecAmp;        // Perform security amplification
			
		/* Radio communication */
		interface SplitControl as RadioControl;
		interface Packet as RadioPacket;
		interface AMPacket as RadioAMPacket;
	    	
		/* Messages via radio */
		interface AMSend as MeasureSend;
		interface Receive as MeasureReceive;

		interface AMSend as DistancesSend;
		interface Receive as DistancesReceive;

		interface AMSend as SecAmplifSend;
		interface Receive as SecAmplifReceive;

		interface AMSend as VerifySend;
		interface Receive as VerifyReceive;
		interface AMSend as VerifyRespSend;
		interface Receive as VerifyRespReceive;

		interface CC2420Packet; // Provides RSSI values, can be used to set up transmit power
		interface Random;
		interface AES;
	}
	
}
implementation{
	uint8_t m_state = STATE_RSSI_MEASURE;

	// Currently the table of neighbors is not created dynamically
	// offset 0 is used for nen exting node ID
	neighbors_t tableOfNeighbors[1+MAX_NEIGHBORS];   
	uint8_t secAmplifNodeOffset = 1;
	uint8_t neighborCount = 0;
	message_t pkt;
	uint8_t receivedMsg = 0;
	
	static void fatal_problem() {}
	
	// ##############################  BOOTED  ###################################  
	event void Boot.booted() {
#ifdef  INCLUDE_BODY
		uint8_t i = 0;		  
		
		// The node has booted.
		call Leds.led0On(); 
		
		// starts the radio stack
		if (call RadioControl.start() != SUCCESS)
			fatal_problem();

		// initialize table of neighbours
		for (i = 1; i <= MAX_NEIGHBORS; i++) {
			tableOfNeighbors[i].nodeId = 0;
			tableOfNeighbors[i].avgRSSI = 0;
			tableOfNeighbors[i].avgRSSICount = 0;
			tableOfNeighbors[i].secAmplifStatus = SA_STATUS_INIT;
			tableOfNeighbors[i].secAmplifState = SA_STATE_INIT;
		}

		// set the first node state for sending and accepting measure packets
		m_state = STATE_RSSI_MEASURE;
    
		call TimerBootDelay.startOneShot(20000);	
#endif	
	}

	event void TimerBootDelay.fired() {
#ifdef  INCLUDE_BODY
		pl_log(4, "BOOT", "The node ID: %u has booted\n", TOS_NODE_ID);
		pl_log(4, "STATE", "######## Entering state STATE_RSSI_MEASURE\n");	
		pl_printfflush();

		call TimerMeasurePacket.startPeriodic(TIMER_MEASURE_PACKET_DELAY);	
		call TimerMeasureEnd.startOneShot(TIMER_MEASURE_PACKET_PERIOD_LENGTH);
#endif	
	}

	// Getting proper node offset
	// Zero is returned for non existing nodeId
	uint8_t getNodeOffset(uint16_t nodeId) {
#ifdef  INCLUDE_BODY
		uint8_t i = 1;

		for (i = 1; i <= MAX_NEIGHBORS; i++) {
			if (tableOfNeighbors[i].nodeId == nodeId) {
				return i;
			}
		}  		

		return 0;
#endif	
	}

	// Calculating the hash value
	void hashData(uint8_t* inBlock, uint8_t* keyValue, uint8_t* hash) {
#ifdef  INCLUDE_BODY
		uint8_t m_exp[240];
       
        	call AES.keyExpansion(m_exp, (uint8_t*) keyValue);		
        	call AES.encrypt(inBlock, m_exp, hash);
#endif	
	}

	// ########################  STATE_RSSI_MEASURE  #############################
	// RSSI measure packet send
	task void sendMeasure() {
#ifdef  INCLUDE_BODY
		measureMsg_t* nmsg = (measureMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		nmsg->senderId = TOS_NODE_ID;
		
		call MeasureSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(measureMsg_t));
#endif	
	} 
  
	// RSSI measure packet received
	event message_t * MeasureReceive.receive(message_t *msg, void *payload, uint8_t len) {
#ifdef  INCLUDE_BODY
		measureMsg_t* nmsg = (measureMsg_t*) payload;
    		
		int8_t rssi = (call CC2420Packet.getRssi(msg)) - 45;
    
		uint8_t nodeOffset = getNodeOffset(nmsg->senderId);

		// store received rssi for averaging  
		// update RSSI values only if the node is in proper phase
		if (m_state == STATE_RSSI_MEASURE) {
			// if the node does not exist, add it to the neighbour table
			if (nodeOffset == 0) {
				neighborCount++;
				tableOfNeighbors[neighborCount].nodeId = nmsg->senderId;
				nodeOffset = neighborCount;
			}

			tableOfNeighbors[nodeOffset].avgRSSI += rssi;          
			tableOfNeighbors[nodeOffset].avgRSSICount++;
		}
#endif			
		return msg;
	}

	// ########################  STATE_SECRECY_AMPLIF  ###########################
	// Packet with RSSI distances is send	  
	task void sendMeasuredRSSI() {
#ifdef  INCLUDE_BODY
		// select nodes with good RSSI estimation (significant number of measure packets received) and broadcast measured RSSI values
		uint8_t	numCommNeighbours = 0;	
		uint8_t i = 1;
    
		distancesMsg_t* nmsg = (distancesMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		nmsg->senderId = TOS_NODE_ID;

		pl_log(4, "RSSI SND", "Sending measured RSSI packet:\n");
		pl_printfflush();

		for (i = 1; i <= MAX_NEIGHBORS; i++) {
			if ((tableOfNeighbors[i].avgRSSICount >= MEASURE_PACKETS_MIN_REQUIRED) && (numCommNeighbours < MAX_COMMUNICATION_NEIGHBORS)) {
				nmsg->measuredRSSI[numCommNeighbours].nodeId = tableOfNeighbors[i].nodeId;
				nmsg->measuredRSSI[numCommNeighbours].rssi = tableOfNeighbors[i].avgRSSI;
        
				pl_log(4, ":", "\tNode ID: %u\tAverage RSSI: %d\n", tableOfNeighbors[i].nodeId, tableOfNeighbors[i].avgRSSI);        
 				pl_printfflush();       
				numCommNeighbours++;
			}
		}

		call DistancesSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(distancesMsg_t));
#endif	
	}
  
	void deriveSharedKeyMaster(uint16_t nodeId) {
#ifdef  INCLUDE_BODY
		uint8_t nodeOffset = getNodeOffset(nodeId);
		uint8_t i = 0;
		for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
			tableOfNeighbors[nodeOffset].sharedKey[i] ^= tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[i] ^ tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[i]; 
		}
#endif	
	}

	void deriveSharedKeySlave(uint16_t nodeId) {
#ifdef  INCLUDE_BODY
		uint8_t nodeOffset = getNodeOffset(nodeId);
		uint8_t i = 0;
		for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
			tableOfNeighbors[nodeOffset].sharedKey[i] ^= tableOfNeighbors[nodeOffset].amplifValueHybridSlave1[i] ^ tableOfNeighbors[nodeOffset].amplifValueHybridSlave2[i]; 
		}
#endif	
	}

	// ##########################  HYBRID PROTOCOLS  #############################
	void executeHybrid1(uint8_t nodeOffset) {
#ifdef  INCLUDE_BODY
		secamplifMsg_t* nmsg = (secamplifMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		uint8_t i = 0;

		nmsg->masterId = TOS_NODE_ID;
		nmsg->slaveId = tableOfNeighbors[nodeOffset].nodeId;
		nmsg->forwarderId = tableOfNeighbors[nodeOffset].forwarderHybrid1;
		nmsg->protocolIndex = 1;
    
		// generate random number
		for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
			tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[i] = call Random.rand16();
			nmsg->amplifValue[i] = tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[i];
		}

 		pl_log(4, "HP SND", "SA: [%u] HP: [01] MASTER: %u, SLAVE: %u\n", m_state-2, nmsg->masterId, nmsg->slaveId);
		pl_printfflush();
		call SecAmplifSend.send(tableOfNeighbors[nodeOffset].forwarderHybrid1, &pkt, sizeof(secamplifMsg_t));
   
		tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_READYFORHYBRID2;
#endif	
	}

	void executeHybrid2(uint8_t nodeOffset) {
#ifdef  INCLUDE_BODY
		secamplifMsg_t* nmsg = (secamplifMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		uint8_t i = 0;

		nmsg->masterId = TOS_NODE_ID;
		nmsg->slaveId = tableOfNeighbors[nodeOffset].nodeId;
		nmsg->forwarderId = tableOfNeighbors[nodeOffset].forwarderHybrid2;
		nmsg->protocolIndex = 2;
   
		// generate random number
		for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
			tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[i] = call Random.rand16();
			nmsg->amplifValue[i] = tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[i];  
		}    

 		pl_log(4, "HP SND", "SA: [%u] HP: [02] MASTER: %u, SLAVE: %u\n", m_state-2, nmsg->masterId, nmsg->slaveId);
		pl_printfflush();
		call SecAmplifSend.send(tableOfNeighbors[nodeOffset].forwarderHybrid2, &pkt, sizeof(secamplifMsg_t));
    
		tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_VERIFY_RDY;
#endif	
	}
  
	event message_t * SecAmplifReceive.receive(message_t *msg, void *payload, uint8_t len) {
#ifdef  INCLUDE_BODY
		secamplifMsg_t* nmsg = (secamplifMsg_t*) payload;

		secamplifMsg_t* forwMsg = (secamplifMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		uint8_t nodeOffset = getNodeOffset(nmsg->masterId);
		uint8_t i = 0;

		if (nmsg->slaveId == TOS_NODE_ID) {
 			pl_log(4, "HP RCV", "SA: [%u] HP: [%u] MASTER: %u, SLAVE: %u\n", m_state-2, nmsg->protocolIndex, nmsg->masterId, nmsg->slaveId);
			pl_printfflush();
			// I'm slave, sub-key is for me
			if (nmsg->protocolIndex == 1) {
				for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
					tableOfNeighbors[nodeOffset].amplifValueHybridSlave1[i] = nmsg->amplifValue[i];
				}
			}
			if (nmsg->protocolIndex == 2) {
				for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
					tableOfNeighbors[nodeOffset].amplifValueHybridSlave2[i] = nmsg->amplifValue[i]; 
				}
			}
		}
		if (nmsg->forwarderId == TOS_NODE_ID) {
			// I'm just forwarder, rebroadcast message
			forwMsg->masterId = nmsg->masterId;
			forwMsg->slaveId = nmsg->slaveId;
			forwMsg->forwarderId = nmsg->forwarderId;
			forwMsg->protocolIndex = nmsg->protocolIndex;
			
			for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
				forwMsg->amplifValue[i] = nmsg->amplifValue[i];
			}      
      
			call SecAmplifSend.send(nmsg->slaveId, &pkt, sizeof(secamplifMsg_t));
		}
#endif
		return msg;       	             
	}  

	// ####################  HYBRID PROTOCOLS VERIFICATION #######################
	void verifyHybrid(uint8_t nodeOffset) {
#ifdef  INCLUDE_BODY
		uint8_t hash[16];
		verifyMsg_t* nmsg = (verifyMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		nmsg->masterId = TOS_NODE_ID;
		nmsg->slaveId = tableOfNeighbors[nodeOffset].nodeId;
		

		hashData(tableOfNeighbors[nodeOffset].amplifValueHybridMaster1, tableOfNeighbors[nodeOffset].amplifValueHybridMaster2, hash);
		memcpy(&nmsg->requiredValuesMask, hash, 2);
 
		//nmsg->requiredValuesMask = tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[0] ^ tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[0];
    
		pl_log(4, "HV SND", "MASTER: %u, SLAVE: %u\n", nmsg->masterId, nmsg->slaveId);
		//pl_log(4, ":", "\t\tHybridMaster1: %u\n", tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[0]);
		//pl_log(4, ":", "\t\tHybridMaster2: %u\n", tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[0]);
		//pl_log(4, ":", "\t\tHash value: %u\n", nmsg->requiredValuesMask);
     		pl_printfflush();

		call VerifySend.send(tableOfNeighbors[nodeOffset].nodeId, &pkt, sizeof(verifyMsg_t));
   
		tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_VERIFY_WAITING;
#endif	
	}	

	event message_t * VerifyReceive.receive(message_t *msg, void *payload, uint8_t len) {
#ifdef  INCLUDE_BODY
		// Test if sub-keys were already received
		
		verifyMsg_t* nmsg = (verifyMsg_t*) payload;
		verifyResponseMsg_t* respMsg = (verifyResponseMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		uint8_t nodeOffset = getNodeOffset(nmsg->masterId);
		uint8_t hash[16];

		if (nmsg->slaveId == TOS_NODE_ID) {
			respMsg->masterId = nmsg->masterId;
			respMsg->slaveId = nmsg->slaveId;

			hashData(tableOfNeighbors[nodeOffset].amplifValueHybridSlave1, tableOfNeighbors[nodeOffset].amplifValueHybridSlave2, hash);
			memcpy(&respMsg->calculatedValuesMask, hash, 2);
			
			//respMsg->calculatedValuesMask = tableOfNeighbors[nodeOffset].amplifValueHybridSlave1[0] ^ tableOfNeighbors[nodeOffset].amplifValueHybridSlave2[0];
			//pl_log(4, "VERIFICATION", "CHECK\n");			
			//pl_log(4, ":", "\t\tHybridMaster1: %u\n", tableOfNeighbors[nodeOffset].amplifValueHybridSlave1[0]);
			//pl_log(4, ":", "\t\tHybridMaster2: %u\n", tableOfNeighbors[nodeOffset].amplifValueHybridSlave2[0]);
			//pl_log(4, ":", "\t\tHash value: %u\n", respMsg->calculatedValuesMask);
			if (nmsg->requiredValuesMask == respMsg->calculatedValuesMask) {
				deriveSharedKeySlave(nmsg->masterId);		
			}

			call VerifyRespSend.send(respMsg->masterId, &pkt, sizeof(verifyResponseMsg_t));
		}

#endif
		return msg;	
	}

	event message_t * VerifyRespReceive.receive(message_t *msg, void *payload, uint8_t len) {
#ifdef  INCLUDE_BODY
		verifyResponseMsg_t* nmsg = (verifyResponseMsg_t*) payload;
		uint8_t nodeOffset = getNodeOffset(nmsg->slaveId);
		
		uint8_t hash[16];	
		uint16_t verify;
		hashData(tableOfNeighbors[nodeOffset].amplifValueHybridMaster1, tableOfNeighbors[nodeOffset].amplifValueHybridMaster2, hash);
		memcpy(&verify, hash, 2);

		if (nmsg->masterId == TOS_NODE_ID) {
			if (nmsg->calculatedValuesMask != verify) { 
				// amplification was unsuccesfull, repeat
				tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_READYFORHYBRID1;   
				pl_log(4, "HV RCV", "MASTER: %u, SLAVE: %u NOT OK!\n", nmsg->masterId, nmsg->slaveId);
				pl_printfflush();
			}
			else { 
				// ok, node is done, derive shared key
				tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_RDY; 
				deriveSharedKeyMaster(nmsg->slaveId);
				pl_log(4, "HV RCV", "MASTER: %u, SLAVE: %u OK!\n", nmsg->masterId, nmsg->slaveId); 
				pl_printfflush();     
			}
		}
#endif	
		return msg;
	}

	// #######################  SECURITY AMPLIFICATION  ##########################
	task void performSecrecyAmplif() {    
#ifdef  INCLUDE_BODY
		if (m_state < STATE_OPERATIONAL) { 
			// process another node in queue if its amplification status is OK
			if(tableOfNeighbors[secAmplifNodeOffset].secAmplifStatus == SA_STATUS_OK) {
				switch (tableOfNeighbors[secAmplifNodeOffset].secAmplifState) {
					case SA_STATE_READYFORHYBRID1: {
						executeHybrid1(secAmplifNodeOffset);
						break;
					}
					case SA_STATE_READYFORHYBRID2: {
						executeHybrid2(secAmplifNodeOffset);
						break;
					}
					case SA_STATE_VERIFY: {
						verifyHybrid(secAmplifNodeOffset);
						break;          
					}
					default: {
						break;
					}
				}
			}
			// move to next node for serving
			secAmplifNodeOffset++;
			if (secAmplifNodeOffset > MAX_NEIGHBORS) secAmplifNodeOffset = 1;
			      
			post performSecrecyAmplif(); 
		}
#endif	
	}

	// Packet with RSSI distances is received
	event message_t * DistancesReceive.receive(message_t *msg, void *payload, uint8_t len) {
#ifdef  INCLUDE_BODY
		distancesMsg_t* nmsg = (distancesMsg_t*) payload;

		uint8_t myNeighbour = 0;
		uint8_t elseNeighbour = 0;

		int16_t distance_nc = 0;
		int16_t distance_np = 0;
		
		int16_t minResultAmp1 = 30000;
		int16_t minResultAmp2 = 30000;

		uint16_t forwarderAmp1 = 0;
		uint16_t forwarderAmp2 = 0;



		// NOTE: conversion from log normal shadowing model to linear must be performed
		if (m_state == STATE_RSSI_SEND_REC) {
			uint8_t nodeOffset = getNodeOffset(nmsg->senderId);
      
			pl_log(4, "RSSI RCV", "Measured RSSI packet from node ID %u:\n", nmsg->senderId);      
			pl_printfflush();
			for (elseNeighbour = 0; elseNeighbour < MAX_COMMUNICATION_NEIGHBORS; elseNeighbour++) {
				for (myNeighbour = 1; myNeighbour <= MAX_NEIGHBORS; myNeighbour++) {
					if ((tableOfNeighbors[myNeighbour].nodeId == nmsg->measuredRSSI[elseNeighbour].nodeId) && (tableOfNeighbors[myNeighbour].nodeId != 0)) {					
						//we have common neighbour						
						distance_np = ~(nmsg->measuredRSSI[elseNeighbour].rssi) + 1;
						distance_nc = ~(tableOfNeighbors[myNeighbour].avgRSSI) + 1;	

						if ((((distance_nc-69)*(distance_nc-69))+((distance_np-98)*(distance_np-98))) < minResultAmp1) {
							forwarderAmp1 = tableOfNeighbors[myNeighbour].nodeId;
							minResultAmp1 = (((distance_nc-69)*(distance_nc-69))+((distance_np-98)*(distance_np-98)));
						}

						if ((((distance_nc-1)*(distance_nc-1))+((distance_np-39)*(distance_np-39))) < minResultAmp2) {
							forwarderAmp2 = tableOfNeighbors[myNeighbour].nodeId;
							minResultAmp2 = (((distance_nc-1)*(distance_nc-1))+((distance_np-39)*(distance_np-39)));
						}
					}

				}

				pl_log(4, ":", "\tNode ID: %u\tAverage RSSI: %d\n", nmsg->measuredRSSI[elseNeighbour].nodeId, nmsg->measuredRSSI[elseNeighbour].rssi); 						
				pl_printfflush();
			} 
                 
			if ((forwarderAmp1 != 0) && (forwarderAmp2 != 0)) {      
				tableOfNeighbors[nodeOffset].forwarderHybrid1 = forwarderAmp1;
				tableOfNeighbors[nodeOffset].forwarderHybrid2 = forwarderAmp2;
				
				pl_log(4, ":", "\tForw1: %u\tForw2: %u\tMinAmp1: %u\tMinAmp2: %u\n", tableOfNeighbors[getNodeOffset(nmsg->senderId)].forwarderHybrid1, tableOfNeighbors[getNodeOffset(nmsg->senderId)].forwarderHybrid2, minResultAmp1, minResultAmp2); 
				pl_printfflush();
				tableOfNeighbors[nodeOffset].secAmplifStatus = SA_STATUS_OK;
				tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_RDY;				
			}
		}
#endif	
		return msg;   
	}

	// ##############################  TIMERS  ###################################
	event void TimerMeasurePacket.fired() {
#ifdef  INCLUDE_BODY
		post sendMeasure();
#endif	
	}
  
	event void TimerMeasureEnd.fired() {
#ifdef  INCLUDE_BODY
		uint8_t i = 0;		
		// stop sending measure packets
		call TimerMeasurePacket.stop(); 
		// change internal state to RSSI computation, send and receive
		m_state = STATE_RSSI_SEND_REC;   

		pl_log(4, "STATE", "######## Entering state STATE_RSSI_SEND_REC\n"); 
		pl_printfflush();
		// Compute average of received RSSI
		for (i = 1; i <= MAX_NEIGHBORS; i++) {
			if (tableOfNeighbors[i].avgRSSICount > 0) tableOfNeighbors[i].avgRSSI = tableOfNeighbors[i].avgRSSI / tableOfNeighbors[i].avgRSSICount;
		}	
    
		call TimerSendRSSI.startOneShot(TIMER_SEND_RSSI_DELAY);
#endif	
	}
  
	event void TimerSendRSSI.fired() {
#ifdef  INCLUDE_BODY
		post sendMeasuredRSSI();
		call TimerSecAmp.startPeriodic(TIMER_AMP_DURATION); 
#endif	 
	}

	event void TimerVerify.fired() {
#ifdef  INCLUDE_BODY
		uint8_t i = 0;
		for (i = 1; i <= MAX_NEIGHBORS; i++) {
			if (tableOfNeighbors[i].secAmplifState == SA_STATE_VERIFY_RDY) {
				tableOfNeighbors[i].secAmplifState = SA_STATE_VERIFY;      
			} 
			if (tableOfNeighbors[i].secAmplifState == SA_STATE_VERIFY_WAITING) {
				tableOfNeighbors[i].secAmplifState = SA_STATE_READYFORHYBRID1;
			}   
		}    
#endif	
	}  
	
	event void TimerSecAmp.fired() {
#ifdef  INCLUDE_BODY
		uint8_t i = 0;
    
		// move to the next phase
		m_state++;
		       

		if (m_state < STATE_OPERATIONAL) { 
			pl_log(4, "STATE", "######## Entering state SA%u\n", m_state-2);	
			pl_printfflush();	
			// check all neighbors status and state
			for (i = 1; i <= MAX_NEIGHBORS; i++) {
				if (tableOfNeighbors[i].secAmplifState != SA_STATE_RDY) {
					tableOfNeighbors[i].secAmplifState = SA_STATE_INIT;    
					tableOfNeighbors[i].secAmplifStatus = SA_STATUS_NOK;    
				} else {
					tableOfNeighbors[i].secAmplifState = SA_STATE_READYFORHYBRID1;			        
				}   
			}              
			// perform secrecy amplification  
			post performSecrecyAmplif(); 
			call TimerVerify.startPeriodic(TIMER_VERIFY_DELAY);
		} else {
			call TimerSecAmp.stop(); 
			call TimerVerify.stop();
			pl_log(4, "STATE", "######## Entering OPERATIONAL state\n");	
			pl_printfflush();	   
		}     
#endif	 
	}
  
	// #######################  NON IMPLEMENTED EVENTS  ##########################
	event void RadioControl.startDone(error_t error){
		if (error != SUCCESS) fatal_problem();
	}
	
	event void RadioControl.stopDone(error_t error){}

	event void MeasureSend.sendDone(message_t *msg, error_t error){}

	event void SecAmplifSend.sendDone(message_t *msg, error_t error) {}
	event void VerifyRespSend.sendDone(message_t *msg, error_t error) {}
	event void DistancesSend.sendDone(message_t *msg, error_t error) {}
	event void VerifySend.sendDone(message_t *msg, error_t error) {}
}
