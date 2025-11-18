using UnityEngine;
using UnityEngine.UI;
using TMPro;

public class LearnButtonScript : MonoBehaviour
{
    public Button button;
    public string skillName;
    public GameObject selectedItem;

    public void OnActivate()
    {
        PlayerDataScript playerDataScript = PlayerDataScript.Instance;
        if (skillName == null || selectedItem == null)
        {
            Debug.LogError("skillName or selectedItem have not been set yet");
            return;
        }
        if (playerDataScript.unlockedSkills.Contains(skillName))
        {
            Debug.Log("this skill is already unlocked");
        }
        else
        {
            playerDataScript.unlockedSkills.Add(skillName);
            DestroyImmediate(selectedItem);
            // refresh open UI panels
            Transform characterUI = GameObject.Find("Character UI").transform;
            Transform inventoryUIPanel = characterUI.Find("Inventory UI Panel(Clone)");
            if (inventoryUIPanel != null)
            {
                InventoryUIScript inventoryUIScript = inventoryUIPanel.GetComponent<InventoryUIScript>();
                inventoryUIScript.RefreshUI();
            }
            // close context menu
            Transform canvas = GameObject.Find("Canvas").transform;
            Transform contextMenu = canvas.Find("Context Menu");
            if (contextMenu != null)
            {
                Destroy(contextMenu.gameObject);
            }
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
