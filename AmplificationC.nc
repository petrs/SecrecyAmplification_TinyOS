#include "Amplification.h"
#include "printf.h"

module AmplificationC {
	uses {
		interface Boot;
		interface Leds;
		interface Timer<TMilli> as TimerMeasurePacket; // Sending measure packets 
		interface Timer<TMilli> as TimerMeasureEnd;    // RSSI_MEASUERE state
		interface Timer<TMilli> as TimerSendRSSI;      // Sends measured RSSI
		interface Timer<TMilli> as TimerVerify;        // Delays verification message to make delivery possible 
		interface Timer<TMilli> as TimerBootDelay;     // Delays all operations after boot, for connecting serial interfaces
		interface Timer<TMilli> as TimerAmpDelay;      // Delay between RSSI send and actual amplification
			
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
	}
	
}
implementation{
	uint8_t m_state = STATE_RSSI_MEASURE;

	// Currently the table of neighbors is not created dynamically
	neighbors_t tableOfNeighbors[1+MAX_NEIGHBORS];   // offset 0 is used for nen exting node ID
	uint8_t secAmplifNodeOffset = 1;
	uint8_t secAmplifNodeSkipped = 0;  
	uint8_t neighborCount = 0;
	message_t pkt;
	uint8_t receivedMsg = 0;
	
	static void fatal_problem() {}
	
	// ##############################  BOOTED  ###################################  
	event void Boot.booted() {
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
			tableOfNeighbors[i].secAmplifState = SA_STATE_INIT;
		}

		// set the first node state for sending and accepting measure packets
		m_state = STATE_RSSI_MEASURE;
    
		call TimerBootDelay.startOneShot(20000);		
	}

	event void TimerBootDelay.fired() {
		printf("The node ID: %u has booted\n", TOS_NODE_ID);
		printf("Sendig measure packets \t\t\".\" \n");
		printf("Receiving measure packets \tID of sending node \n");
		printfflush();

		call TimerMeasurePacket.startPeriodic(TIMER_MEASURE_PACKET_DELAY);	
		call TimerMeasureEnd.startOneShot(TIMER_MEASURE_PACKET_PERIOD_LENGTH);
		call TimerSendRSSI.startOneShot(TIMER_SEND_RSSI_DELAY);
		call TimerAmpDelay.startOneShot(60000);
	}

	// Getting proper node offset
	// Zero is returned for non existing nodeId
	uint8_t getNodeOffset(uint16_t nodeId) {
		uint8_t i = 1;

		for (i = 1; i <= MAX_NEIGHBORS; i++) {
			if (tableOfNeighbors[i].nodeId == nodeId) {
				return i;
			}
		}  		

		return 0;
	}

	// ########################  STATE_RSSI_MEASURE  #############################
	// RSSI measure packet send
	task void sendMeasure() {
		measureMsg_t* nmsg = (measureMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		nmsg->senderId = TOS_NODE_ID;
		
		call MeasureSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(measureMsg_t));
    
		printf(".");
		printfflush(); 
	} 
  
	// RSSI measure packet received
	event message_t * MeasureReceive.receive(message_t *msg, void *payload, uint8_t len) {
		measureMsg_t* nmsg = (measureMsg_t*) payload;
		
		int8_t rssi = (call CC2420Packet.getRssi(msg)) - 45;

		// store received rssi for averaging  
		// update RSSI values only if the node is in proper phase
		if (m_state == STATE_RSSI_MEASURE) {
			// if the node does not exist, add it to the neighbour table
			if (getNodeOffset(nmsg->senderId) == 0) {
				neighborCount++;
				tableOfNeighbors[neighborCount].nodeId = nmsg->senderId;
			}

			tableOfNeighbors[getNodeOffset(nmsg->senderId)].avgRSSI += rssi;          
			tableOfNeighbors[getNodeOffset(nmsg->senderId)].avgRSSICount++;
      
			printf("%u", nmsg->senderId);
			printfflush();
		}
		
		return msg;
	}

	// ########################  STATE_SECRECY_AMPLIF  ###########################
	// Packet with RSSI distances is send	  
	task void sendMeasuredRSSI() {
		// select nodes with good RSSI estimation (significant number of measure packets received) and broadcast measured RSSI values
		uint8_t	numCommNeighbours = 0;	
		uint8_t i = 1;
    
		distancesMsg_t* nmsg = (distancesMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		nmsg->senderId = TOS_NODE_ID;

		printf("\nSending measured RSSI packet:\n");
		printfflush();

		for (i = 1; i <= MAX_NEIGHBORS; i++) {
			if ((tableOfNeighbors[i].avgRSSICount >= MEASURE_PACKETS_MIN_REQUIRED) && (numCommNeighbours < MAX_COMMUNICATION_NEIGHBORS)) {
				nmsg->measuredRSSI[numCommNeighbours].nodeId = tableOfNeighbors[i].nodeId;
				nmsg->measuredRSSI[numCommNeighbours].rssi = tableOfNeighbors[i].avgRSSI;
        
				printf("\tNode ID: %u\tAverage RSSI: %d\n", tableOfNeighbors[i].nodeId, tableOfNeighbors[i].avgRSSI);
				printfflush();                
        
				numCommNeighbours++;
			}
		}

		call DistancesSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(distancesMsg_t));
	}
  
	void deriveSharedKeyMaster(uint16_t nodeId) {
		uint8_t nodeOffset = getNodeOffset(nodeId);
		uint8_t i = 0;
		// TODO: combine existing and new key values into new one using hash function
		for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
			tableOfNeighbors[nodeOffset].sharedKey[i] ^= tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[i] ^ tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[i]; 
		}
	}

	void deriveSharedKeySlave(uint16_t nodeId) {
		uint8_t nodeOffset = getNodeOffset(nodeId);
		uint8_t i = 0;
		// TODO: combine existing and new key values into new one using hash function
		for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
			tableOfNeighbors[nodeOffset].sharedKey[i] ^= tableOfNeighbors[nodeOffset].amplifValueHybridSlave1[i] ^ tableOfNeighbors[nodeOffset].amplifValueHybridSlave2[i]; 
		}
	}

	// ##########################  HYBRID PROTOCOLS  #############################
	void executeHybrid1(uint8_t nodeOffset) {
		secamplifMsg_t* nmsg = (secamplifMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		uint8_t i = 0;

		nmsg->masterId = TOS_NODE_ID;
		nmsg->slaveId = tableOfNeighbors[nodeOffset].nodeId;
		nmsg->forwarderId = tableOfNeighbors[nodeOffset].forwarderHybrid1;
		nmsg->protocolIndex = 1;
    
		printf("\nGenerated random number for hybrid 1: ");
		// generate random number
		for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
			tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[i] = call Random.rand16();
			nmsg->amplifValue[i] = tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[i];
			printf("%u.", tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[i]);
			printfflush();
		}

 		printf("\nSending hybrid 1: MASTER: %u, FORWARDER: %u, SLAVE: %u", nmsg->masterId, nmsg->forwarderId, nmsg->slaveId);
		printfflush(); 

		call SecAmplifSend.send(tableOfNeighbors[nodeOffset].forwarderHybrid1, &pkt, sizeof(secamplifMsg_t));
   
		tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_READYFORHYBRID2;
	}

	void executeHybrid2(uint8_t nodeOffset) {
		secamplifMsg_t* nmsg = (secamplifMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		uint8_t i = 0;

		nmsg->masterId = TOS_NODE_ID;
		nmsg->slaveId = tableOfNeighbors[nodeOffset].nodeId;
		nmsg->forwarderId = tableOfNeighbors[nodeOffset].forwarderHybrid2;
		nmsg->protocolIndex = 2;

		printf("\nGenerated random number for hybrid 2: ");    
		// generate random number
		for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
			tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[i] = call Random.rand16();
			nmsg->amplifValue[i] = tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[i];
			printf("%u.", tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[i]);
			printfflush();      
		}    

 		printf("\nSending hybrid 2: MASTER: %u, FORWARDER: %u, SLAVE: %u", nmsg->masterId, nmsg->forwarderId, nmsg->slaveId);
		printfflush(); 

		call SecAmplifSend.send(tableOfNeighbors[nodeOffset].forwarderHybrid2, &pkt, sizeof(secamplifMsg_t));
    
		tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_VERIFY_RDY;
		call TimerVerify.startOneShot(TIMER_VERIFY_DELAY);
	}
  
	event message_t * SecAmplifReceive.receive(message_t *msg, void *payload, uint8_t len) {
		secamplifMsg_t* nmsg = (secamplifMsg_t*) payload;

		secamplifMsg_t* forwMsg = (secamplifMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		uint8_t nodeOffset = getNodeOffset(nmsg->masterId);
		uint8_t i = 0;

		if (nmsg->slaveId == TOS_NODE_ID) {
 			printf("\nReceiving hybrid %u: MASTER: %u, FORWARDER: %u, SLAVE: %u", nmsg->protocolIndex, nmsg->masterId, nmsg->forwarderId, nmsg->slaveId);
			printfflush(); 

			// I'm slave, sub-key is for me
			printf("\nReceived value for protocol %u: ", nmsg->protocolIndex);
			printfflush();
			if (nmsg->protocolIndex == 1) {
				for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
					tableOfNeighbors[nodeOffset].amplifValueHybridSlave1[i] = nmsg->amplifValue[i];
					printf("%u.", nmsg->amplifValue[i]);  
				}
			}
			if (nmsg->protocolIndex == 2) {
				for (i = 0; i < AMPLIF_VALUE_LENGTH; i++) {
					tableOfNeighbors[nodeOffset].amplifValueHybridSlave2[i] = nmsg->amplifValue[i];
					printf("%u.", nmsg->amplifValue[i]);  
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

			printf("\nForwarding hybrid %u... MASTER: %u, FORWARDER: %u, SLAVE: %u, MASK: %u", forwMsg->protocolIndex, forwMsg->masterId, forwMsg->forwarderId, forwMsg->slaveId, forwMsg->amplifValue[0]);
			printfflush();      
      
			call SecAmplifSend.send(nmsg->slaveId, &pkt, sizeof(secamplifMsg_t));
		}
		return msg;
	}  

	// ####################  HYBRID PROTOCOLS VERIFICATION #######################
	void verifyHybrid(uint8_t nodeOffset) {
		verifyMsg_t* nmsg = (verifyMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		nmsg->masterId = TOS_NODE_ID;
		nmsg->slaveId = tableOfNeighbors[nodeOffset].nodeId;
		// TODO: Implement hash function    
		nmsg->requiredValuesMask = tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[0] ^ tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[0];
    
		printf("\nSending verification... MASTER: %u, SLAVE: %u, MASK: %u", nmsg->masterId, nmsg->slaveId, nmsg->requiredValuesMask);
		printfflush();
     		
		call VerifySend.send(tableOfNeighbors[nodeOffset].nodeId, &pkt, sizeof(verifyMsg_t));
   
		tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_VERIFY_WAITING;
	}	

	event message_t * VerifyReceive.receive(message_t *msg, void *payload, uint8_t len) {
		// Test if sub-keys were already received
		
		verifyMsg_t* nmsg = (verifyMsg_t*) payload;
		verifyResponseMsg_t* respMsg = (verifyResponseMsg_t*) call RadioPacket.getPayload(&pkt, call RadioPacket.maxPayloadLength());
		uint8_t nodeOffset = getNodeOffset(nmsg->masterId);

		if (nmsg->slaveId == TOS_NODE_ID) {
			respMsg->masterId = nmsg->masterId;
			respMsg->slaveId = nmsg->slaveId;
			respMsg->calculatedValuesMask = tableOfNeighbors[nodeOffset].amplifValueHybridSlave1[0] ^ tableOfNeighbors[nodeOffset].amplifValueHybridSlave2[0];

			if (nmsg->requiredValuesMask == respMsg->calculatedValuesMask) {
				deriveSharedKeySlave(nmsg->masterId);		
			}

			printf("\nReceiving verification... MASTER: %u, SLAVE: %u, MASK: %u", nmsg->masterId, nmsg->slaveId, nmsg->requiredValuesMask);
			printfflush();
			printf("\nSending verification resp... MASTER: %u, SLAVE: %u, MASK: %u", respMsg->masterId, respMsg->slaveId, respMsg->calculatedValuesMask);
			printfflush();      

			call VerifyRespSend.send(respMsg->masterId, &pkt, sizeof(verifyResponseMsg_t));
		}

		return msg;
	}

	event message_t * VerifyRespReceive.receive(message_t *msg, void *payload, uint8_t len) {
		verifyResponseMsg_t* nmsg = (verifyResponseMsg_t*) payload;
		uint8_t nodeOffset = getNodeOffset(nmsg->slaveId);

		if (nmsg->masterId == TOS_NODE_ID) {
			if (nmsg->calculatedValuesMask != (tableOfNeighbors[nodeOffset].amplifValueHybridMaster1[0] ^ tableOfNeighbors[nodeOffset].amplifValueHybridMaster2[0])) { 
				// amplification was unsuccesfull, repeat
				tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_READYFORHYBRID1;   
				printf("\nReceiving verification resp and NOT OK! MASTER: %u, SLAVE: %u, MASK: %u", nmsg->masterId, nmsg->slaveId, nmsg->calculatedValuesMask);
				printfflush();  
			}
			else { 
				// ok, node is done, derive shared key
				tableOfNeighbors[nodeOffset].secAmplifState = SA_STATE_FINISHED; 
				deriveSharedKeyMaster(nmsg->slaveId);
				printf("\nReceiving verification resp and its OK! MASTER: %u, SLAVE: %u, MASK: %u", nmsg->masterId, nmsg->slaveId, nmsg->calculatedValuesMask);
				printfflush();         
			}
		}
		return msg;
	}

	// #######################  SECURITY AMPLIFICATION  ##########################
	task void performSecrecyAmplif() {    
		if (m_state == STATE_SECRECY_AMPLIF) { //&& (secAmplifNodeSkipped < MAX_NEIGHBORS)) {
			// process another node in queue
			switch (tableOfNeighbors[secAmplifNodeOffset].secAmplifState) {
				case SA_STATE_READYFORHYBRID1: {
					executeHybrid1(secAmplifNodeOffset);
					secAmplifNodeSkipped = 0;
					break;
				}
				case SA_STATE_READYFORHYBRID2: {
					executeHybrid2(secAmplifNodeOffset);
					secAmplifNodeSkipped = 0;
					break;
				}
				case SA_STATE_VERIFY: {
					verifyHybrid(secAmplifNodeOffset);
					secAmplifNodeSkipped = 0;
					break;          
				}
				default: {
					//secAmplifNodeSkipped++;
					break;
				}
			}
      
			// move to next node for serving
			secAmplifNodeOffset++;
			if (secAmplifNodeOffset > MAX_NEIGHBORS) secAmplifNodeOffset = 1;
			      
			post performSecrecyAmplif(); 
		}
	}

	// Packet with RSSI distances is received
	event message_t * DistancesReceive.receive(message_t *msg, void *payload, uint8_t len) {
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
		if (m_state == STATE_SECRECY_AMPLIF) {
			
			printf("\nReceiving measured RSSI packet from node ID %u:\n", nmsg->senderId);
			printfflush();
			
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

				printf("\tNode ID: %u\tAverage RSSI: %d\n", nmsg->measuredRSSI[elseNeighbour].nodeId, nmsg->measuredRSSI[elseNeighbour].rssi); 				
				printfflush();			
			} 
                 
			if ((forwarderAmp1 != 0) && (forwarderAmp2 != 0)) {
				tableOfNeighbors[getNodeOffset(nmsg->senderId)].forwarderHybrid1 = forwarderAmp1;
				tableOfNeighbors[getNodeOffset(nmsg->senderId)].forwarderHybrid2 = forwarderAmp2;
				
				printf("\tForw1: %u\tForw2: %u\tMinAmp1: %u\tMinAmp2: %u\n", tableOfNeighbors[getNodeOffset(nmsg->senderId)].forwarderHybrid1, tableOfNeighbors[getNodeOffset(nmsg->senderId)].forwarderHybrid2, minResultAmp1, minResultAmp2); 
				printfflush();

				tableOfNeighbors[getNodeOffset(nmsg->senderId)].secAmplifState = SA_STATE_READYFORHYBRID1;
				//post performSecrecyAmplif();
				
			}
		}

		return msg;           
	}

	// ##############################  TIMERS  ###################################
	event void TimerMeasurePacket.fired() {
		post sendMeasure();
	}
  
	event void TimerMeasureEnd.fired() {
		uint8_t i = 0;		
		// stop sending measure packets
		call TimerMeasurePacket.stop(); 
		// change internal state to RSSI computation
		m_state = STATE_COMPUTE_RSSI;   

		// Compute average of received RSSI
		for (i = 1; i < MAX_NEIGHBORS; i++) {
			if (tableOfNeighbors[i].avgRSSICount > 0) tableOfNeighbors[i].avgRSSI = tableOfNeighbors[i].avgRSSI / tableOfNeighbors[i].avgRSSICount;
		}	
		// change internal state to secrecy amplification
		m_state = STATE_SECRECY_AMPLIF;
	}
  
	event void TimerSendRSSI.fired() {
		post sendMeasuredRSSI();  
	}

	event void TimerVerify.fired() {
		uint8_t i = 0;
		for (i = 1; i < MAX_NEIGHBORS; i++) {
			if (tableOfNeighbors[i].secAmplifState == SA_STATE_VERIFY_RDY) {
				tableOfNeighbors[i].secAmplifState = SA_STATE_VERIFY;      
			}    
		}    
	}  
	
	event void TimerAmpDelay.fired() {
		post performSecrecyAmplif();  
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
