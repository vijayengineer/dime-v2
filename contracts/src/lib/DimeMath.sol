// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title DimeMath — settlement arithmetic (external library, linked at deploy)
/// @dev Mirrors src/domain/math.ts in the frontend. Rounding: trader-owed amounts floor toward
///      -inf, fees and trader-owed-by amounts round up; dust goes to the house.
library DimeMath {
    uint256 internal constant BPS = 1e4;

    struct PairResult {
        bool longWins;
        uint256 loss; // paid by loser
        uint256 base; // part of loss passed to winner
        uint256 gapPaid; // from house backstop
        uint256 winnerGross;
        uint256 fee;
    }

    function floorDiv(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) != (b < 0)) q -= 1;
    }

    /// floor(dir × collateral × leverage × (exit − entry) / entry)
    function rawPnl(bool isLong, uint256 collateral, uint256 leverage, uint256 entry, uint256 exit)
        public pure returns (int256)
    {
        int256 notional = int256(collateral * leverage);
        int256 delta = int256(exit) - int256(entry);
        if (!isLong) delta = -delta;
        return floorDiv(notional * delta, int256(entry));
    }

    /// The part of a win the house keeps: a win of m bp pays m × m / (m + k), so the cut is gross × k / (m + k).
    /// k and m are in hundredths of a bp. m floors and the cut rounds up (dust goes to the house).
    function winCut(int256 gross, uint256 entry, uint256 exit, uint256 kE2) public pure returns (uint256) {
        if (gross <= 0 || kE2 == 0) return 0;
        uint256 d = exit > entry ? exit - entry : entry - exit;
        uint256 mE2 = (d * 1e6) / entry;
        uint256 g = uint256(gross);
        uint256 cut = (g * kE2 + mE2 + kE2 - 1) / (mE2 + kE2);
        return cut > g ? g : cut;
    }

    /// House route gross P&L: loss capped at collateral, win capped at reservation.
    function houseGross(
        bool isLong, uint256 collateral, uint256 leverage, uint256 entry, uint256 exit, uint256 reservation, bool liquidation
    ) public pure returns (int256 gross) {
        if (liquidation) return -int256(collateral);
        gross = rawPnl(isLong, collateral, leverage, entry, exit);
        if (gross < -int256(collateral)) gross = -int256(collateral);
        if (gross > int256(reservation)) gross = int256(reservation);
    }

    /// Matched pair: loser's loss funds the winner; gap beyond loser collateral paid only from
    /// the reserved backstop (maxGrossWin − loser collateral).
    function pair(
        uint256 collateral, uint256 leverage, uint256 entry, uint256 exit, uint256 maxGrossWin, uint256 kE2, bool liquidation
    ) public pure returns (PairResult memory r) {
        int256 longRaw = rawPnl(true, collateral, leverage, entry, exit);
        int256 shortRaw = rawPnl(false, collateral, leverage, entry, exit);
        r.longWins = longRaw > 0;
        int256 wRaw = r.longWins ? longRaw : shortRaw;
        int256 xRaw = r.longWins ? shortRaw : longRaw;
        if (liquidation) r.loss = collateral;
        else r.loss = xRaw < 0 ? _min(uint256(-xRaw), collateral) : 0;
        uint256 backstop = maxGrossWin > collateral ? maxGrossWin - collateral : 0;
        r.base = liquidation ? r.loss : (wRaw > 0 ? _min(uint256(wRaw), r.loss) : 0);
        uint256 gap = wRaw > 0 && uint256(wRaw) > r.loss ? uint256(wRaw) - r.loss : 0;
        r.gapPaid = _min(gap, backstop);
        r.winnerGross = r.base + r.gapPaid;
        r.fee = winCut(int256(r.winnerGross), entry, exit, kE2);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) { return a < b ? a : b; }
}
