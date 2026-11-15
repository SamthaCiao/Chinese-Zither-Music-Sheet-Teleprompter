<script type="application/json" def>
{
  "navigationBarTitleText": "看谱"
}
</script>

<script setup>
import wx from 'wx';
import { keepQuery } from '../../inbox.js';

export default {
  data: {
    line: '导入谱子'
  },

  onLoad(query) {
    this.hand(query);
  },

  onShow(query) {
    this.hand(query);
  },

  hand(query) {
    let pages = [];
    try { pages = (typeof getCurrentPages === 'function') ? getCurrentPages() : []; } catch (e) { pages = []; }
    let handed = false;
    if (query) {
      for (let i = pages.length - 1; i >= 0; i--) {
        const page = pages[i];
        if (page && page !== this && typeof page.acceptQuery === 'function') {
          page.acceptQuery(query);
          handed = true;
          break;
        }
      }
      if (!handed) keepQuery(query);
    }
    if (handed && pages.length > 1 && wx && wx.navigateBack) {
      try { wx.navigateBack(); } catch (e) {}
      return;
    }
    if (!handed && wx && wx.redirectTo) {
      try { wx.redirectTo({ url: '/pages/index/index' }); } catch (e) {}
    }
  }
};
</script>

<page>
  <view class="root">
    <text class="line">{{line}}</text>
  </view>
</page>

<style>
.root {
  width: 480px;
  height: 352px;
  background: #000000;
  display: flex;
  align-items: center;
  justify-content: center;
}
.line {
  width: 480px;
  color: #40FF5E;
  font-size: 36px;
  line-height: 52px;
  text-align: center;
}
</style>
