import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import test from 'node:test';
import { Keypair, PublicKey, SystemProgram, TransactionInstruction, SYSVAR_CLOCK_PUBKEY, SYSVAR_RENT_PUBKEY, TransactionMessage, VersionedTransaction, ComputeBudgetProgram } from '@solana/web3.js';
import { ADDRESSES, derive, fundAddresses, publicKey } from '../helpers/addresses.ts';
import { decodePool, discriminator } from '../helpers/layouts.ts';
import { localConnection, testAta, testWallet, requireLoopback } from '../helpers/localnet.ts';
import { bindingPayload, mandateHash, fundId, integer, word, addressWord, factory, policyAddresses } from '../core/fixtures.ts';
import { attest, evm } from '../cctp/fixtures.ts';
import { instruction, sendMeasured, u128 } from '../raydium/client.ts';

test('composed authenticated Fund lifecycle on cloned mainnet programs', { timeout: 7_200_000 }, async () => {
  const connection = localConnection(); requireLoopback(connection.rpcEndpoint);
  assert.equal(new URL(connection.rpcEndpoint).port, process.env.PP_LOCALNET_RPC_PORT ?? '8899');
  const manager = testWallet(); const keeper = testWallet('keeper');
  const core = Buffer.alloc(20, 0xa8);
  const pool = decodePool((await connection.getAccountInfo(publicKey(ADDRESSES.tslaxPool)))!.data);
  const target = policyAddresses(manager.publicKey, core, 8, pool);
  const fund = publicKey(target.fund); const vault = publicKey(target.vault);
  const ledger = (mint: string) => derive(ADDRESSES.spoke, Buffer.from('ledger'), fund.toBuffer(), publicKey(mint).toBuffer());
  const pda = (program: string, ...seeds: Buffer[]) => derive(program, ...seeds);
  const key = (address: string | PublicKey, writable = false, signer = false) => ({ pubkey: typeof address === 'string' ? publicKey(address) : address, isWritable: writable, isSigner: signer });
  const transit = (id: Buffer, outbound = false) => pda(ADDRESSES.spoke, Buffer.from(outbound ? 'transit_out' : 'transit_in'), fund.toBuffer(), id);
  const route = pda(ADDRESSES.spoke, Buffer.from('cctp_route'), fund.toBuffer());
  const transportLedger = pda(ADDRESSES.spoke, Buffer.from('cctp_ledger'), fund.toBuffer());
  const usdc = testAta(ADDRESSES.usdc, vault); const tslax = testAta(ADDRESSES.tslax, vault);
  const evidence: { step: string; units?: number; bytes: number; signature: string }[] = [];
  async function send(step: string, operation: TransactionInstruction, payer = manager, signers: Keypair[] = []) {
    const result = await sendMeasured(connection, payer, operation, signers);
    evidence.push({ step, ...result });
    writeFileSync(new URL('../../.localnet/rehearsal-metrics.json', import.meta.url), JSON.stringify(evidence, null, 2));
    return result;
  }
  const common = { authority: manager.publicKey, fund, vault, system_program: SystemProgram.programId };
  const initAccounts = { ...common, usdc_mint: ADDRESSES.usdc, tslax_mint: ADDRESSES.tslax, wsol_mint: ADDRESSES.wsol,
    usdc_ata: usdc, tslax_ata: tslax, wsol_ata: testAta(ADDRESSES.wsol, vault), usdc_ledger: ledger(ADDRESSES.usdc),
    tslax_ledger: ledger(ADDRESSES.tslax), wsol_ledger: ledger(ADDRESSES.wsol), cctp_route: route, cctp_ledger: transportLedger,
    token_program: ADDRESSES.token, token_2022_program: ADDRESSES.token2022, ata_program: ADDRESSES.ata };
  const fullBootstrap = bindingPayload(manager.publicKey, core, 8, 2_000_000_000n, pool);
  const compactBootstrap = Buffer.concat([Buffer.from([1]), fullBootstrap.subarray(0, 134), fullBootstrap.subarray(174)]);
  const initialize = instruction('initialize_fund', initAccounts, compactBootstrap);
  await send('initialize dual consent', initialize);
  assert.equal((await connection.getAccountInfo(fund))!.owner.toBase58(), ADDRESSES.spoke);
  await assert.rejects(sendMeasured(connection, manager, initialize), /InvalidConfiguration/);
  const unbound = instruction('initialize_adapter', { ...common, authority: keeper.publicKey, venue_program: ADDRESSES.kamino,
    venue: ADDRESSES.reserve, position_or_policy: pda(ADDRESSES.spoke, Buffer.from('position'), fund.toBuffer(), publicKey(ADDRESSES.reserve).toBuffer()),
    collateral_or_ledger: testAta('B8V6WVjPxW1UGwVDfxH2d2r8SyT4cqn7dQRK6XneVa7D', vault), collateral_mint: 'B8V6WVjPxW1UGwVDfxH2d2r8SyT4cqn7dQRK6XneVa7D', token_program: ADDRESSES.token, ata_program: ADDRESSES.ata }, Buffer.alloc(0));
  await assert.rejects(sendMeasured(connection, keeper, unbound), /UnauthorizedManager/);
  const inboundId = word(801); const nonce = word(1801);
  const messenger = pda(ADDRESSES.cctpMessenger, Buffer.from('token_messenger'));
  const transmitter = pda(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter'));
  const messengerData = (await connection.getAccountInfo(publicKey(messenger)))!.data;
  const feeAta = testAta(ADDRESSES.usdc, new PublicKey(messengerData.subarray(109,141)));
  const message = Buffer.alloc(536);
  for (const [offset,value] of [[0,1],[4,3],[8,5],[140,1000],[144,1000],[148,1]]) message.writeUInt32BE(value,offset);
  nonce.copy(message,12); evm('28b5a0e9c621a5badaa536219b3a228c8168cf5d').copy(message,44);
  publicKey(ADDRESSES.cctpMessenger).toBuffer().copy(message,76); vault.toBuffer().copy(message,108);
  evm('af88d065e77c8cc2239327c5edb3a432268e5831').copy(message,152); usdc.toBuffer().copy(message,184);
  word(50_000_000).copy(message,216); addressWord(core).copy(message,248); word(10_000).copy(message,280); word(100).copy(message,312);
  Buffer.concat([word(1),fundId,word(42161),inboundId,word(0)]).copy(message,376);
  const receiveAccounts = { authority: keeper.publicKey, fund, vault, route, ledger: transportLedger, transit: transit(inboundId), usdc_ata: usdc, token_ledger: ledger(ADDRESSES.usdc), system_program: SystemProgram.programId };
  function receive(bytes: Buffer) {
    const signature = attest(bytes);
    const operation = instruction('receive_and_credit', receiveAccounts, Buffer.concat([inboundId,integer(bytes.length,4),bytes,integer(signature.length,4),signature]));
    operation.keys.push(...[
      key(keeper.publicKey,true,true),key(vault),key(pda(ADDRESSES.cctpTransmitter,Buffer.from('message_transmitter_authority'),publicKey(ADDRESSES.cctpMessenger).toBuffer())),
      key(transmitter),key(pda(ADDRESSES.cctpTransmitter,Buffer.from('used_nonce'),nonce),true),key(ADDRESSES.cctpMessenger),key(SystemProgram.programId),
      key(pda(ADDRESSES.cctpTransmitter,Buffer.from('__event_authority'))),key(ADDRESSES.cctpTransmitter),key(messenger),
      key(pda(ADDRESSES.cctpMessenger,Buffer.from('remote_token_messenger'),Buffer.from('3'))),key(pda(ADDRESSES.cctpMessenger,Buffer.from('token_minter'))),
      key(pda(ADDRESSES.cctpMessenger,Buffer.from('local_token'),publicKey(ADDRESSES.usdc).toBuffer()),true),
      key(pda(ADDRESSES.cctpMessenger,Buffer.from('token_pair'),Buffer.from('3'),evm('af88d065e77c8cc2239327c5edb3a432268e5831'))),key(feeAta,true),key(usdc,true),
      key(pda(ADDRESSES.cctpMessenger,Buffer.from('custody'),publicKey(ADDRESSES.usdc).toBuffer()),true),key(ADDRESSES.token),
      key(pda(ADDRESSES.cctpMessenger,Buffer.from('__event_authority'))),key(ADDRESSES.cctpMessenger),key(ADDRESSES.cctpTransmitter)]);
    return operation;
  }
  const wrongSender = Buffer.from(message); wrongSender[248] ^= 1;
  await assert.rejects(sendMeasured(connection,keeper,receive(wrongSender)), /WrongSender/);
  await send('CCTP receive credit',receive(message),keeper);
  assert.equal((await connection.getAccountInfo(publicKey(ledger(ADDRESSES.usdc))))!.data.readBigUInt64LE(72),49_999_900n);
  const collateral = 'B8V6WVjPxW1UGwVDfxH2d2r8SyT4cqn7dQRK6XneVa7D';
  const kaminoPosition = pda(ADDRESSES.spoke,Buffer.from('position'),fund.toBuffer(),publicKey(ADDRESSES.reserve).toBuffer());
  const collateralAta = testAta(collateral,vault);
  await send('initialize Kamino admission',instruction('initialize_adapter',{...common,venue_program:ADDRESSES.kamino,venue:ADDRESSES.reserve,position_or_policy:kaminoPosition,collateral_or_ledger:collateralAta,collateral_mint:collateral,token_program:ADDRESSES.token,ata_program:ADDRESSES.ata},Buffer.alloc(0)));
  const kaminoAccounts = {...common,position:kaminoPosition,kamino_program:ADDRESSES.kamino,market:ADDRESSES.market,reserve:ADDRESSES.reserve,
    market_authority:pda(ADDRESSES.kamino,Buffer.from('lma'),publicKey(ADDRESSES.market).toBuffer()),liquidity_mint:ADDRESSES.usdc,collateral_mint:collateral,
    liquidity_supply:'Bgq7trRgVMeq33yt235zM2onQ4bRDBsY5EWiTetF4qw6',vault_usdc:usdc,vault_collateral:collateralAta,token_program:ADDRESSES.token,
    instructions_sysvar:'Sysvar1nstructions1111111111111111111111111',token_ledger:ledger(ADDRESSES.usdc)};
  let supply: TransactionInstruction | undefined;
  for(let offset=0;offset<32;offset++) {
    const candidate=instruction('kamino_supply',kaminoAccounts,integer(10_000_000+offset,8));
    const transaction=new VersionedTransaction(new TransactionMessage({payerKey:manager.publicKey,recentBlockhash:(await connection.getLatestBlockhash()).blockhash,instructions:[ComputeBudgetProgram.setComputeUnitLimit({units:600_000}),candidate]}).compileToV0Message());
    transaction.sign([manager]); const simulation=await connection.simulateTransaction(transaction);
    if(!simulation.value.err){supply=candidate;break;}
  }
  assert.ok(supply,'find exact Kamino debit within 32 raw units'); await send('Kamino supply',supply);
  const recorded=JSON.parse(readFileSync(new URL('../swap/fixtures/tslax.json',import.meta.url),'utf8'));
  const routeData=Buffer.from(recorded.instructions.swapInstruction.data,'base64');
  const swap=instruction('swap_to_ratio',{...common,swap_program:recorded.instructions.swapInstruction.programId},Buffer.concat([publicKey(ADDRESSES.usdc).toBuffer(),publicKey(ADDRESSES.tslax).toBuffer(),integer(15_000_000,8),integer(BigInt(recorded.quote.otherAmountThreshold),8),integer(200,2),integer(routeData.length,4),routeData]));
  const substitutions = new Map([[recorded.vault, vault], [recorded.instructions.swapInstruction.accounts[2].pubkey, usdc], [recorded.instructions.swapInstruction.accounts[3].pubkey, tslax]]);
  swap.keys.push(...recorded.instructions.swapInstruction.accounts.map((account:any)=>key(substitutions.get(account.pubkey)??account.pubkey,account.isWritable,false)),key(ledger(ADDRESSES.usdc),true),key(ledger(ADDRESSES.tslax),true));
  await send('Jupiter V1 recorded ratio leg (T5b replacement)',swap);
  const policy=pda(ADDRESSES.spoke,Buffer.from('raydium_policy'),fund.toBuffer(),publicKey(ADDRESSES.tslaxPool).toBuffer());
  const lpLedger=pda(ADDRESSES.spoke,Buffer.from('raydium_ledger'),fund.toBuffer(),publicKey(ADDRESSES.tslaxPool).toBuffer());
  await send('initialize Raydium admission',instruction('initialize_adapter',{...common,venue_program:ADDRESSES.raydium,venue:ADDRESSES.tslaxPool,position_or_policy:policy,collateral_or_ledger:lpLedger,collateral_mint:ADDRESSES.usdc,token_program:ADDRESSES.token,ata_program:ADDRESSES.ata},Buffer.alloc(0)));
  const nftMint=Keypair.generate(); const personal=pda(ADDRESSES.raydium,Buffer.from('position'),nftMint.publicKey.toBuffer());
  const record=pda(ADDRESSES.spoke,Buffer.from('position'),fund.toBuffer(),publicKey(personal).toBuffer());
  const lower=Math.floor(pool.tickCurrent/pool.tickSpacing)*pool.tickSpacing-10*pool.tickSpacing; const upper=lower+20*pool.tickSpacing;
  const array=(tick:number)=>{const start=Buffer.alloc(4);start.writeInt32BE(Math.floor(tick/(60*pool.tickSpacing))*60*pool.tickSpacing);return pda(ADDRESSES.raydium,Buffer.from('tick_array'),publicKey(ADDRESSES.tslaxPool).toBuffer(),start);};
  const lpAccounts={...common,raydium_program:ADDRESSES.raydium,policy,ledger:lpLedger,position_record:record,nft_mint:nftMint.publicKey,
    nft_account:pda(ADDRESSES.ata,vault.toBuffer(),publicKey(ADDRESSES.token2022).toBuffer(),nftMint.publicKey.toBuffer()),pool:ADDRESSES.tslaxPool,
    protocol_position:ADDRESSES.raydium,tick_array_lower:array(lower),tick_array_upper:array(upper),personal_position:personal,
    token_account_0:testAta(pool.mint0,vault),token_account_1:testAta(pool.mint1,vault),token_vault_0:pool.vault0,token_vault_1:pool.vault1,
    rent:SYSVAR_RENT_PUBKEY,token_program:ADDRESSES.token,associated_token_program:ADDRESSES.ata,token_program_2022:ADDRESSES.token2022,
    mint_0:pool.mint0,mint_1:pool.mint1,bitmap:pda(ADDRESSES.raydium,Buffer.from('pool_tick_array_bitmap_extension'),publicKey(ADDRESSES.tslaxPool).toBuffer()),
    memo_program:'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr',rent_payer:manager.publicKey};
  const ticks=Buffer.alloc(8);ticks.writeInt32LE(lower);ticks.writeInt32LE(upper,4);
  const liquidity=1_000_000n;
  await send('Raydium open TSLAx USDC',instruction('raydium_open_position',lpAccounts,Buffer.concat([ticks,u128(liquidity),integer(1_000_000,8),integer(1_000_000,8),u128(liquidity)])),manager,[nftMint]);
  const reportMessage=Keypair.generate();
  const publish=instruction('publish_report',{...common,authority:keeper.publicKey,wormhole_program:ADDRESSES.wormhole,emitter:target.emitter,
    bridge:pda(ADDRESSES.wormhole,Buffer.from('Bridge')),sequence:pda(ADDRESSES.wormhole,Buffer.from('Sequence'),publicKey(target.emitter).toBuffer()),
    fee_collector:pda(ADDRESSES.wormhole,Buffer.from('fee_collector')),message:reportMessage.publicKey,clock:SYSVAR_CLOCK_PUBKEY,rent:SYSVAR_RENT_PUBKEY},Buffer.alloc(0));
  publish.keys.push(key(ledger(ADDRESSES.usdc)),key(usdc),key(ledger(ADDRESSES.tslax)),key(tslax),key(ADDRESSES.tslax),
    key(kaminoPosition),key(collateralAta),key(ADDRESSES.kamino),key(ADDRESSES.market),key(ADDRESSES.reserve,true),
    key(record),key(ADDRESSES.tslaxPool),key(personal),key(array(lower)),key(array(upper)),key(pool.vault0),key(pool.vault1),key(transit(inboundId)));
  await send('publish exhaustive v6 report',publish,keeper,[reportMessage]);
  const posted=(await connection.getAccountInfo(reportMessage.publicKey))!.data;
  assert.equal(posted[4],32); const bytes=posted.subarray(95);
  writeFileSync(new URL('../../.localnet/rehearsal-report.hex',import.meta.url),`0x${bytes.toString('hex')}\n`);
  assert.equal(bytes.readBigUInt64BE(24),6n);
  const positionOffset=Number(bytes.readBigUInt64BE(64+8*32+24));assert.equal(bytes.readBigUInt64BE(64+positionOffset+24),2n);
  await send('Raydium collect fees',instruction('raydium_collect_fees',lpAccounts,Buffer.alloc(0)));
  await send('Raydium close position',instruction('raydium_close_position',lpAccounts,Buffer.alloc(16)));
  await send('Kamino withdraw all',instruction('kamino_redeem',kaminoAccounts,Buffer.concat([integer((1n<<64n)-1n,8),integer(1,8)])));
  const outboundId=word(802); const event=Keypair.generate();
  const principal=(await connection.getAccountInfo(publicKey(ledger(ADDRESSES.usdc))))!.data.readBigUInt64LE(72);
  const burn=instruction('send_to_hub',{...common,route,ledger:transportLedger,transit:transit(outboundId,true),usdc_ata:usdc,token_ledger:ledger(ADDRESSES.usdc),event_account:event.publicKey},Buffer.concat([outboundId,integer(principal,8),integer(1000,8)]));
  burn.keys.push(...[key(vault),key(manager.publicKey,true,true),key(pda(ADDRESSES.cctpMessenger,Buffer.from('sender_authority'))),key(usdc,true),
    key(pda(ADDRESSES.cctpMessenger,Buffer.from('denylist_account'),vault.toBuffer())),key(transmitter,true),key(messenger),key(pda(ADDRESSES.cctpMessenger,Buffer.from('remote_token_messenger'),Buffer.from('3'))),
    key(pda(ADDRESSES.cctpMessenger,Buffer.from('token_minter'))),key(pda(ADDRESSES.cctpMessenger,Buffer.from('local_token'),publicKey(ADDRESSES.usdc).toBuffer()),true),key(ADDRESSES.usdc,true),key(event.publicKey,true,true),
    key(ADDRESSES.cctpTransmitter),key(ADDRESSES.cctpMessenger),key(ADDRESSES.token),key(SystemProgram.programId),key(pda(ADDRESSES.cctpMessenger,Buffer.from('__event_authority'))),key(ADDRESSES.cctpMessenger),key(ADDRESSES.cctpMessenger)]);
  await send('CCTP send principal home',burn,manager,[event]);
  const acknowledgements = JSON.parse(readFileSync(new URL('../../.localnet/rehearsal-acks.json', import.meta.url), 'utf8'));
  function acknowledge(posted: string) {
    const operation = instruction('execute_order', { ...common, authority: keeper.publicKey, wormhole_program: ADDRESSES.wormhole, posted_vaa: posted }, Buffer.alloc(0));
    operation.keys.push(key(transit(outboundId,true), true), key(transportLedger, true));
    return operation;
  }
  await assert.rejects(sendMeasured(connection, keeper, acknowledge(acknowledgements.wrongEmitter)), /InvalidOrder/);
  await send('sealed Hub arrival ACK (local guardian fixture)', acknowledge(acknowledgements.valid), keeper);
  assert.equal((await connection.getAccountInfo(fund))!.data.readUInt16LE(374), 1);
  assert.equal((await connection.getAccountInfo(publicKey(transit(outboundId,true))))!.data.at(-2), 1);
  assert.equal((await connection.getAccountInfo(vault))?.lamports??0,0);
  assert.equal((await connection.getAccountInfo(fund))!.data.readUInt16LE(372),0);
  assert.equal((await connection.getAccountInfo(publicKey(ledger(ADDRESSES.usdc))))!.data.readBigUInt64LE(72),0n);
  console.log(`Lifecycle complete: ${evidence.length} actual transactions; ${bytes.length} native report bytes; no mainnet transaction.`);
});
