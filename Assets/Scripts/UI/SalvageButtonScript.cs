using UnityEngine;
using UnityEngine.UI;
using TMPro;
using System.Collections;

public class SalvageButtonScript : MonoBehaviour
{
    public Button button;
    public TMP_Text salvageText;
    public PlayerDataScript.Salvage salvageValue;
    public GameObject selectedItem;

    public IEnumerator SetText(PlayerDataScript.Salvage itemSalvage)
    {
        string buildingString = "Salvage";
        if (itemSalvage.wood > 0)
        {
            buildingString += $" {itemSalvage.wood} wood";
        }
        if (itemSalvage.metal > 0)
        {
            buildingString += $" {itemSalvage.metal} metal";
        }
        if (itemSalvage.leather > 0)
        {
            buildingString += $" {itemSalvage.leather} leather";
        }
        if (itemSalvage.cloth > 0)
        {
            buildingString += $" {itemSalvage.cloth} cloth";
        }
        if (itemSalvage.knowledge > 0)
        {
            buildingString += $" {itemSalvage.knowledge} knowledge";
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
        PlayerDataScript.Instance.collectedSalvage += salvageValue;
        DestroyImmediate(selectedItem);
        // refresh open menus
        Transform characterUI = GameObject.Find("Character UI").transform;
        Transform gearMenu = characterUI.Find("Gear Menu(Clone)");
        if (gearMenu != null)
        {
            GearMenuScript gearMenuScript = gearMenu.GetComponent<GearMenuScript>();
            gearMenuScript.RefreshUI();
        }
        Transform inventoryMenu = characterUI.Find("Inventory Menu(Clone)");
        if (inventoryMenu != null)
        {
            InventoryMenuScript inventoryMenuScript = inventoryMenu.GetComponent<InventoryMenuScript>();
            inventoryMenuScript.RefreshUI();
        }
        // refresh skills panel in case equipped weapon was salvaged
        GameObject skillsPanel = GameObject.Find("Skills Panel");
        SkillBarScript skillBarScript = skillsPanel.GetComponent<SkillBarScript>();
        skillBarScript.UpdateButtons();
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
