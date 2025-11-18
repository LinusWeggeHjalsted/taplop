using UnityEngine;
using UnityEngine.UI;
using TMPro;
using System.Collections;

public class SalvageButtonScript : MonoBehaviour
{
    public Button button;
    public TMP_Text salvageText;
    public int[] salvageValue;
    public GameObject selectedItem;

    public IEnumerator SetText(int[] itemSalvage)
    {
        string buildingString = "Salvage";
        if (itemSalvage[0] > 0)
        {
            buildingString += $" {itemSalvage[0]} wood";
        }
        if (itemSalvage[1] > 0)
        {
            buildingString += $" {itemSalvage[1]} metal";
        }
        if (itemSalvage[2] > 0)
        {
            buildingString += $" {itemSalvage[2]} leather";
        }
        if (itemSalvage[3] > 0)
        {
            buildingString += $" {itemSalvage[3]} knowledge";
        }
        while (salvageText == null)
        {
            yield return null;
        }
        salvageText.text = buildingString;
    }

    public void OnActivate()
    {
        if (salvageValue == null || selectedItem == null)
        {
            Debug.LogError("salvageValue or selectedItem not set yet");
            return;
        }
        PlayerDataScript playerDataScript = PlayerDataScript.Instance;
        playerDataScript.woodSalvage += salvageValue[0];
        playerDataScript.metalSalvage += salvageValue[1];
        playerDataScript.leatherSalvage += salvageValue[2];
        playerDataScript.knowledge += salvageValue[3];
        DestroyImmediate(selectedItem);
        // refresh open UI panels
        Transform characterUI = GameObject.Find("Character UI").transform;
        Transform gearUIPanel = characterUI.Find("Gear UI Panel(Clone)");
        if (gearUIPanel != null)
        {
            GearUIScript gearUIScript = gearUIPanel.GetComponent<GearUIScript>();
            gearUIScript.RefreshUI();
        }
        Transform inventoryUIPanel = characterUI.Find("Inventory UI Panel(Clone)");
        if (inventoryUIPanel != null)
        {
            InventoryUIScript inventoryUIScript = inventoryUIPanel.GetComponent<InventoryUIScript>();
            inventoryUIScript.RefreshUI();
        }
        // refresh skills panel in case equipped weapon was salvaged
        GameObject skillsPanel = GameObject.Find("Skills Panel");
        SkillsPanelScript skillsPanelScript = skillsPanel.GetComponent<SkillsPanelScript>();
        skillsPanelScript.UpdateButtons();
        // close context menu
        Transform canvas = GameObject.Find("Canvas").transform;
        Transform contextMenu = canvas.Find("Context Menu");
        if (contextMenu != null)
        {
            Destroy(contextMenu.gameObject);
        }
    }

    void Start()
    {
        salvageText = this.transform.Find("Salvage Button Text").gameObject.GetComponent<TMP_Text>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
