using UnityEngine;
using UnityEngine.UI;

public class GearButtonScript : MonoBehaviour
{
    public Button button;
    public Transform characterUI;
    public GameObject gearUIPrefab;
    public GameObject gearUIPanel;

    public void OnActivate()
    {
        if (gearUIPanel == null)
        {
            gearUIPanel = Instantiate(gearUIPrefab, characterUI);
        }
        else
        {
            Destroy(gearUIPanel);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        characterUI = GameObject.Find("Character UI").transform;
        gearUIPrefab = Resources.Load<GameObject>("Prefabs/Gear UI Panel");
    }
}
