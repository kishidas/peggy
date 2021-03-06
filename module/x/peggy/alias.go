package peggy

import (
	"github.com/althea-net/peggy/module/x/peggy/keeper"
	"github.com/althea-net/peggy/module/x/peggy/types"
)

const (
	ModuleName          = types.ModuleName
	RouterKey           = types.RouterKey
	StoreKey            = types.StoreKey
	DefaultParamspace   = types.ModuleName
	QuerierRoute        = types.QuerierRoute
	OutgoingTxBatchSize = keeper.OutgoingTxBatchSize
)

var (
	NewKeeper           = keeper.NewKeeper
	NewQuerier          = keeper.NewQuerier
	NewMsgSetEthAddress = types.NewMsgSetEthAddress
	ModuleCdc           = types.ModuleCdc
	RegisterCodec       = types.RegisterCodec
	DefaultGenesisState = types.DefaultGenesisState
)

type (
	MsgSendToEth                       = types.MsgSendToEth
	MsgRequestBatch                    = types.MsgRequestBatch
	MsgConfirmBatch                    = types.MsgConfirmBatch
	Keeper                             = keeper.Keeper
	MsgSetEthAddress                   = types.MsgSetEthAddress
	MsgValsetConfirm                   = types.MsgValsetConfirm
	MsgValsetRequest                   = types.MsgValsetRequest
	MsgCreateEthereumClaims            = types.MsgCreateEthereumClaims
	MsgBridgeSignatureSubmission       = types.MsgBridgeSignatureSubmission
	EthereumClaim                      = types.EthereumClaim
	EthereumBridgeDepositClaim         = types.EthereumBridgeDepositClaim
	EthereumBridgeWithdrawalBatchClaim = types.EthereumBridgeWithdrawalBatchClaim
	EthereumBridgeMultiSigUpdateClaim  = types.EthereumBridgeMultiSigUpdateClaim
	Params                             = types.Params
	GenesisState                       = types.GenesisState
)
