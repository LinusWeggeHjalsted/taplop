using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;

public class InventoryButtonScript : MonoBehaviour
{
    public Button button;
    public Transform characterUI;
    public GameObject inventoryUIPrefab;
    public GameObject inventoryUIPanel;

    public void OnActivate()
    {
        if (inventoryUIPanel == null)
        {
            inventoryUIPanel = Instantiate(inventoryUIPrefab, characterUI);
        }
        else
        {
            Destroy(inventoryUIPanel);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        characterUI = GameObject.Find("Character UI").transform;
        inventoryUIPrefab = Resources.Load<GameObject>("Prefabs/Inventory UI Panel");
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard != null)
        {
            if (keyboard.iKey.wasPressedThisFrame)
            {
                OnActivate();
            }
        }
    }
}
