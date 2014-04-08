#define NEW_PRINTF_SEMANTICS
#include "printf.h"

configuration AmplificationAppC {

}

implementation {
	components MainC, LedsC, ActiveMessageC as RadioAM, AmplificationC as App;
	components new TimerMilliC() as TimerMeasurePacket;
	components new TimerMilliC() as TimerMeasureEnd;
	components new TimerMilliC() as TimerSendRSSI;
	components new TimerMilliC() as TimerVerify;
	components new TimerMilliC() as TimerAmpDelay;

	// printf
	components new TimerMilliC() as TimerBootDelay;
	App.TimerBootDelay -> TimerBootDelay;
	components PrintfC;
	components SerialStartC;
	
	App.Boot -> MainC;
	App.Leds -> LedsC;
	App.TimerMeasurePacket -> TimerMeasurePacket;
	App.TimerMeasureEnd -> TimerMeasureEnd;
	App.TimerSendRSSI -> TimerSendRSSI;
	App.TimerVerify -> TimerVerify;
	App.TimerAmpDelay -> TimerAmpDelay;

	// Wiring for radio communication 
	App.RadioControl -> RadioAM;
	App.RadioPacket -> RadioAM;
	App.RadioAMPacket -> RadioAM;
	
	components CC2420ActiveMessageC as CC2420AM;
	App.CC2420Packet -> CC2420AM;
  
	components RandomC;
	App.Random->RandomC;


	components new AMSenderC(AM_MEASURE) as MeasureSend; 
	components new AMReceiverC(AM_MEASURE) as MeasureReceive;
	App.MeasureSend -> MeasureSend;
	App.MeasureReceive -> MeasureReceive;

	components new AMSenderC(AM_DISTANCES) as DistancesSend; 
	components new AMReceiverC(AM_DISTANCES) as DistancesReceive;
	App.DistancesSend -> DistancesSend;
	App.DistancesReceive -> DistancesReceive;

	components new AMSenderC(AM_SECAMPLIF) as SecAmplifSend; 
	components new AMReceiverC(AM_SECAMPLIF) as SecAmplifReceive;
	App.SecAmplifSend -> SecAmplifSend;
	App.SecAmplifReceive -> SecAmplifReceive;

	components new AMSenderC(AM_VERIFY) as VerifySend; 
	components new AMReceiverC(AM_VERIFY) as VerifyReceive;
	App.VerifySend -> VerifySend;
	App.VerifyReceive -> VerifyReceive;

	components new AMSenderC(AM_VERIFY_RESP) as VerifyRespSend; 
	components new AMReceiverC(AM_VERIFY_RESP) as VerifyRespReceive;
	App.VerifyRespSend -> VerifyRespSend;
	App.VerifyRespReceive -> VerifyRespReceive;
}
